// The Flutter Windows end of `jjbox/host`. It is a transport, not a policy layer:
// the JSON envelope goes to the Go host process byte for byte. The host is
// request/response only (host.capabilities.events is false), so this plugin does
// not pretend to deliver asynchronous callbacks.
//
// The pipe name is read from JJBOX_HOST_PIPE so a debug build can point at a
// per-user pipe without rebuilding; production uses \\.\pipe\jjbox-host, created
// by the host with an ACL that admits the interactive user only.

#include "jjbox_plugin.h"
#include "jjbox_protocol.h"

#include <windows.h>

#include <bcrypt.h>

#include <cstdio>

#pragma comment(lib, "bcrypt.lib")
#include <commdlg.h>

#pragma comment(lib, "comdlg32.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableValue;

constexpr DWORD kPipeIoTimeoutMs = 10000;

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()),
                                       nullptr, 0, nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), out.data(), size,
                      nullptr, nullptr);
  return out;
}

std::wstring PipeName() {
  wchar_t buffer[512] = {0};
  const DWORD read = GetEnvironmentVariableW(L"JJBOX_HOST_PIPE", buffer, 512);
  if (read > 0 && read < 512) return std::wstring(buffer, read);
  return L"\\\\.\\pipe\\jjbox-host";
}

// Opt-in diagnostic log: set JJBOX_PLUGIN_LOG to a writable path. The plugin
// otherwise stays silent; this is how the Windows runtime proves which stage
// (method channel, worker, PostMessage, callback) is alive.
void DebugLog(const std::string& message) {
  wchar_t path[1024] = {0};
  const DWORD read = GetEnvironmentVariableW(L"JJBOX_PLUGIN_LOG", path, 1024);
  if (read == 0 || read >= 1024) return;
  const std::string utf8 = Utf8FromWide(std::wstring(path, read));
  std::ofstream stream(utf8, std::ios::app);
  if (!stream) return;
  SYSTEMTIME now;
  GetLocalTime(&now);
  char stamp[64];
  snprintf(stamp, sizeof(stamp), "%04d-%02d-%02dT%02d:%02d:%02d.%03d ",
           now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
           now.wSecond, now.wMilliseconds);
  stream << stamp << message << "\n";
}

std::string SniffString(const std::string& payload, const std::string& key) {
  const std::string needle = "\"" + key + "\":\"";
  const size_t start = payload.find(needle);
  if (start == std::string::npos) return {};
  const size_t valueStart = start + needle.size();
  const size_t end = payload.find('"', valueStart);
  if (end == std::string::npos) return {};
  return payload.substr(valueStart, end - valueStart);
}

std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buffer[8];
          snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += c;
        }
    }
  }
  return out;
}

std::string OkEnvelope(const std::string& id, const std::string& resultJson) {
  return "{\"id\":\"" + JsonEscape(id) + "\",\"ok\":true,\"result\":" + resultJson + "}";
}

std::string Base64Encode(const std::vector<unsigned char>& data) {
  static const char* alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((data.size() + 2) / 3) * 4);
  size_t i = 0;
  while (i + 2 < data.size()) {
    const unsigned int value = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    out += alphabet[(value >> 18) & 63];
    out += alphabet[(value >> 12) & 63];
    out += alphabet[(value >> 6) & 63];
    out += alphabet[value & 63];
    i += 3;
  }
  const size_t rest = data.size() - i;
  if (rest == 1) {
    const unsigned int value = data[i] << 16;
    out += alphabet[(value >> 18) & 63];
    out += alphabet[(value >> 12) & 63];
    out += "==";
  } else if (rest == 2) {
    const unsigned int value = (data[i] << 16) | (data[i + 1] << 8);
    out += alphabet[(value >> 18) & 63];
    out += alphabet[(value >> 12) & 63];
    out += alphabet[(value >> 6) & 63];
    out += "=";
  }
  return out;
}

std::string Sha256Hex(const std::vector<unsigned char>& data) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  unsigned char digest[32] = {0};
  DWORD objectSize = 0;
  DWORD resultSize = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) {
    return {};
  }
  BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                    reinterpret_cast<PUCHAR>(&objectSize), sizeof(objectSize),
                    &resultSize, 0);
  std::vector<unsigned char> object(objectSize);
  BCryptCreateHash(algorithm, &hash, object.data(), objectSize, nullptr, 0, 0);
  BCryptHashData(hash, const_cast<PUCHAR>(data.data()),
                 static_cast<ULONG>(data.size()), 0);
  BCryptFinishHash(hash, digest, sizeof(digest), 0);
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  static const char* hex = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (unsigned char byte : digest) {
    out += hex[byte >> 4];
    out += hex[byte & 15];
  }
  return out;
}

std::string ClassifyClipboard(const std::string& text) {
  if (text.empty()) return "unknown";
  if (text.rfind("http://", 0) == 0 || text.rfind("https://", 0) == 0) {
    return "subscription-url";
  }
  static const char* schemes[] = {"vless://", "vmess://", "trojan://", "ss://",
                                  "ssr://", "tuic://", "hysteria2://", "hy2://",
                                  "anytls://", "socks://"};
  for (const char* scheme : schemes) {
    if (text.rfind(scheme, 0) == 0) return "share-link";
  }
  if (text.front() == '{') return "singbox-json";
  if (text.rfind("proxies:", 0) == 0) return "clash-yaml";
  return "unknown";
}

std::string ReadClipboardText() {
  if (!OpenClipboard(nullptr)) return {};
  std::string out;
  if (HANDLE handle = GetClipboardData(CF_UNICODETEXT)) {
    if (const auto* wide = static_cast<const wchar_t*>(GlobalLock(handle))) {
      out = Utf8FromWide(wide);
      GlobalUnlock(handle);
    }
  }
  CloseClipboard();
  return out;
}

struct PickedConfig {
  std::wstring name;
  std::vector<unsigned char> bytes;
};

bool PickConfigFile(PickedConfig* picked) {
  wchar_t path[MAX_PATH] = {0};
  OPENFILENAMEW dialog = {0};
  dialog.lStructSize = sizeof(dialog);
  dialog.lpstrFilter =
      L"Configs\0*.json;*.yaml;*.yml;*.bpf;*.txt\0All files\0*.*\0";
  dialog.lpstrFile = path;
  dialog.nMaxFile = MAX_PATH;
  dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
  if (!GetOpenFileNameW(&dialog)) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {0};
  GetFileSizeEx(file, &size);
  if (size.QuadPart <= 0 || size.QuadPart > 8 * 1024 * 1024) {
    CloseHandle(file);
    return false;
  }
  picked->bytes.resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool ok = ReadFile(file, picked->bytes.data(),
                           static_cast<DWORD>(picked->bytes.size()), &read,
                           nullptr) != FALSE;
  CloseHandle(file);
  if (!ok) return false;
  picked->bytes.resize(read);
  const std::wstring full(path);
  const size_t slash = full.find_last_of(L"\\/");
  picked->name = slash == std::wstring::npos ? full : full.substr(slash + 1);
  return true;
}

// Waits for an overlapped pipe operation. This is the timeout that keeps a
// wedged host from blocking a worker forever; the worker itself is off the
// platform thread.
bool WaitOverlapped(HANDLE pipe, OVERLAPPED* overlapped, DWORD timeout,
                    DWORD* transferred) {
  if (WaitForSingleObject(overlapped->hEvent, timeout) != WAIT_OBJECT_0) {
    CancelIoEx(pipe, overlapped);
    WaitForSingleObject(overlapped->hEvent, 1000);
    return false;
  }
  return GetOverlappedResult(pipe, overlapped, transferred, FALSE) != FALSE;
}

bool WriteAll(HANDLE pipe, const char* data, DWORD length) {
  DWORD written = 0;
  while (written < length) {
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;
    DWORD step = 0;
    const BOOL started = WriteFile(pipe, data + written, length - written,
                                   &step, &overlapped);
    if (started) {
      if (!GetOverlappedResult(pipe, &overlapped, &step, FALSE)) {
        CloseHandle(overlapped.hEvent);
        return false;
      }
    } else if (GetLastError() != ERROR_IO_PENDING ||
               !WaitOverlapped(pipe, &overlapped, kPipeIoTimeoutMs, &step)) {
      CloseHandle(overlapped.hEvent);
      return false;
    }
    CloseHandle(overlapped.hEvent);
    if (step == 0) return false;
    written += step;
  }
  return true;
}

bool ReadAll(HANDLE pipe, char* data, DWORD length) {
  DWORD read = 0;
  while (read < length) {
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;
    DWORD step = 0;
    const BOOL started = ReadFile(pipe, data + read, length - read,
                                  &step, &overlapped);
    if (started) {
      if (!GetOverlappedResult(pipe, &overlapped, &step, FALSE)) {
        CloseHandle(overlapped.hEvent);
        return false;
      }
    } else if (GetLastError() != ERROR_IO_PENDING ||
               !WaitOverlapped(pipe, &overlapped, kPipeIoTimeoutMs, &step)) {
      CloseHandle(overlapped.hEvent);
      return false;
    }
    CloseHandle(overlapped.hEvent);
    if (step == 0) return false;
    read += step;
  }
  return true;
}

class JjboxPlugin;

JjboxPlugin* g_plugin = nullptr;

// One connection. Send is called on a worker thread, never on the platform
// thread; the mutex serialises a write with its matching read.
class HostLink {
 public:
  explicit HostLink(JjboxPlugin* owner) : owner_(owner) {}
  ~HostLink() { Close(); }

  bool Send(const std::string& payload, std::string* response) {
    std::lock_guard<std::mutex> guard(write_mutex_);
    if (!Ensure()) return false;
    jjbox::FrameHeader header{static_cast<uint32_t>(payload.size()), 0};
    if (!WriteAll(pipe_, reinterpret_cast<const char*>(&header), sizeof(header)) ||
        !WriteAll(pipe_, payload.data(), static_cast<DWORD>(payload.size()))) {
      CloseLocked();
      return false;
    }
    jjbox::FrameHeader reply{0, 0};
    if (!ReadAll(pipe_, reinterpret_cast<char*>(&reply), sizeof(reply))) {
      CloseLocked();
      return false;
    }
    if (reply.length > jjbox::kMaxPayloadBytes) {
      CloseLocked();
      return false;
    }
    response->resize(reply.length);
    if (reply.length > 0 && !ReadAll(pipe_, response->data(), reply.length)) {
      CloseLocked();
      return false;
    }
    return true;
  }

  void Close() {
    std::lock_guard<std::mutex> guard(write_mutex_);
    CloseLocked();
  }

 private:
  bool Ensure() {
    if (pipe_ != INVALID_HANDLE_VALUE) return true;
    pipe_ = CreateFileW(PipeName().c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                        nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    return pipe_ != INVALID_HANDLE_VALUE;
  }

  // The caller already holds write_mutex_. A second lock here was the
  // disconnect self-deadlock: Send held the mutex and called Close(), which
  // tried to take it again.
  void CloseLocked() {
    if (pipe_ != INVALID_HANDLE_VALUE) {
      CancelIoEx(pipe_, nullptr);
      CloseHandle(pipe_);
      pipe_ = INVALID_HANDLE_VALUE;
    }
  }

  JjboxPlugin* owner_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  std::mutex write_mutex_;
};

class JjboxPlugin : public flutter::Plugin {
 public:
  explicit JjboxPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), link_(new HostLink(this)) {
    if (auto* view = registrar_->GetView()) {
      // Keep the view handle; the runner parents it only after registration.
      // Resolve the top-level window at post time instead of here.
      view_handle_ = view->GetNativeWindow();
    }
    if (view_handle_ != nullptr) {
      window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
          [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
            if (message == kJjboxPluginCompletionMessage) {
              DrainCompletions();
              return 0;
            }
            return std::nullopt;
          });
    }
    DebugLog("ctor view=" + std::to_string(reinterpret_cast<uintptr_t>(view_handle_)) +
             " delegate=" + std::to_string(window_proc_delegate_id_));
    g_plugin = this;
    commands_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), jjbox::kCommandsChannel,
        &flutter::StandardMethodCodec::GetInstance());
    commands_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });
    callbacks_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), jjbox::kCallbacksChannel,
        &flutter::StandardMethodCodec::GetInstance());
  }

  ~JjboxPlugin() override {
    {
      std::lock_guard<std::mutex> guard(completion_mutex_);
      shutting_down_ = true;
    }
    if (link_) link_->Close();
    {
      std::unique_lock<std::mutex> lock(completion_mutex_);
      completion_cv_.wait(lock, [this] { return in_flight_ == 0; });
    }
    if (window_proc_delegate_id_ != 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
    }
    if (g_plugin == this) g_plugin = nullptr;
  }

  void DrainFromPlatformThread() { DrainCompletions(); }

 private:
  struct Completion {
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
    bool ok = false;
    std::string response;
  };

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() != jjbox::kInvokeMethod) {
      result->NotImplemented();
      return;
    }
    const auto* payload = std::get_if<std::string>(call.arguments());
    if (payload == nullptr) {
      result->Error("bad_args", "jjbox.invoke expects a JSON string");
      return;
    }
    const std::string method = SniffString(*payload, "method");
    const std::string id = SniffString(*payload, "id");
    DebugLog("handle method=" + method + " id=" + id);
    if (method == "clipboard.readCandidate") {
      const std::string text = ReadClipboardText();
      result->Success(EncodableValue(OkEnvelope(
          id, "{\"text\":\"" + JsonEscape(text) + "\",\"likely\":\"" +
                  ClassifyClipboard(text) + "\"}")));
      return;
    }
    if (method == "file.pickConfig") {
      PickedConfig picked;
      if (!PickConfigFile(&picked)) {
        result->Success(EncodableValue(OkEnvelope(id, "null")));
        return;
      }
      result->Success(EncodableValue(OkEnvelope(
          id, "{\"name\":\"" + JsonEscape(Utf8FromWide(picked.name)) +
                  "\",\"content\":\"" + Base64Encode(picked.bytes) +
                  "\",\"sha256\":\"" + Sha256Hex(picked.bytes) + "\"}")));
      return;
    }

    // Host calls run on a worker. The platform thread returns immediately; the
    // result is delivered from DrainCompletions after PostMessage. That makes a
    // hung host a timeout, not a frozen UI thread.
    {
      std::lock_guard<std::mutex> guard(completion_mutex_);
      in_flight_++;
    }
    std::thread([this, payload = std::string(*payload),
                 result = std::move(result)]() mutable {
      std::string response;
      const bool ok = link_->Send(payload, &response);
      DebugLog("send ok=" + std::string(ok ? "1" : "0") +
               " request=" + std::to_string(payload.size()) +
               " response=" + std::to_string(response.size()));
      {
        std::lock_guard<std::mutex> guard(completion_mutex_);
        auto completion = std::make_unique<Completion>();
        completion->result = std::move(result);
        completion->ok = ok;
        completion->response = std::move(response);
        completions_.push_back(std::move(completion));
      }
      HWND target = view_handle_ != nullptr ? GetAncestor(view_handle_, GA_ROOT)
                                            : nullptr;
      if (target != nullptr) {
        const BOOL posted =
            PostMessageW(target, kJjboxPluginCompletionMessage, 0, 0);
        DebugLog("post target=" + std::to_string(reinterpret_cast<uintptr_t>(target)) +
                 " result=" + std::string(posted ? "1" : "0") +
                 " error=" + std::to_string(GetLastError()));
      } else {
        DebugLog("post skipped: no top-level hwnd");
      }
      {
        std::lock_guard<std::mutex> guard(completion_mutex_);
        in_flight_--;
      }
      completion_cv_.notify_all();
    }).detach();
  }

  void DrainCompletions() {
    std::vector<std::unique_ptr<Completion>> ready;
    {
      std::lock_guard<std::mutex> guard(completion_mutex_);
      ready.swap(completions_);
    }
    DebugLog("drain count=" + std::to_string(ready.size()));
    for (auto& completion : ready) {
      if (completion->ok) {
        completion->result->Success(EncodableValue(completion->response));
      } else {
        completion->result->Error("transport_unavailable",
                                  "jjbox host pipe is not reachable or timed out");
      }
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<HostLink> link_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> commands_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> callbacks_;
  HWND view_handle_ = nullptr;
  int window_proc_delegate_id_ = 0;
  std::mutex completion_mutex_;
  std::condition_variable completion_cv_;
  std::vector<std::unique_ptr<Completion>> completions_;
  int in_flight_ = 0;
  bool shutting_down_ = false;
};

}  // namespace

void JjboxPluginRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<JjboxPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

void JjboxPluginDrainCompletions() {
  if (g_plugin != nullptr) {
    g_plugin->DrainFromPlatformThread();
  }
}
