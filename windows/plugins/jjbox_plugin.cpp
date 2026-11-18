// The Flutter Windows end of `jjbox/host`. It is a transport, not a policy layer:
// the JSON envelope goes to the Go host process byte for byte. A small callback
// pump polls `events.poll` and forwards each host event to `jjbox/host/callback`.
//
// The pipe name is read from JJBOX_HOST_PIPE so a debug build can point at a
// per-user pipe without rebuilding; production uses \\.\pipe\jjbox-host, created
// by the host with an ACL that admits the interactive user only.

#include "jjbox_plugin.h"
#include "jjbox_protocol.h"

#include <windows.h>
#include <shellapi.h>

#pragma comment(lib, "shell32.lib")

#include <bcrypt.h>

#include <cstdio>

#pragma comment(lib, "bcrypt.lib")
#include <commdlg.h>

#pragma comment(lib, "comdlg32.lib")

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cwchar>
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

bool SniffBool(const std::string& payload, const std::string& key) {
  return payload.find("\"" + key + "\":true") != std::string::npos;
}

int SniffInt(const std::string& payload, const std::string& key, int fallback = 0) {
  const std::string needle = "\"" + key + "\":";
  const size_t start = payload.find(needle);
  if (start == std::string::npos) return fallback;
  size_t cursor = start + needle.size();
  bool negative = false;
  if (cursor < payload.size() && payload[cursor] == '-') {
    negative = true;
    cursor++;
  }
  int value = 0;
  bool any = false;
  while (cursor < payload.size() && payload[cursor] >= '0' && payload[cursor] <= '9') {
    any = true;
    value = value * 10 + (payload[cursor] - '0');
    cursor++;
  }
  if (!any) return fallback;
  return negative ? -value : value;
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

std::string Base64Decode(const std::string& text) {
  auto value_of = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  std::vector<unsigned char> out;
  out.reserve((text.size() / 4) * 3);
  int accumulator = 0;
  int bits = 0;
  for (char c : text) {
    if (c == '=') break;
    const int value = value_of(c);
    if (value < 0) continue;
    accumulator = (accumulator << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<unsigned char>((accumulator >> bits) & 0xFF));
    }
  }
  return std::string(out.begin(), out.end());
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
          [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
              -> std::optional<LRESULT> {
            if (message == kJjboxPluginCompletionMessage) {
              DrainCompletions();
              return 0;
            }
            if (message == kJjboxPluginEventMessage) {
              DrainEvents();
              return 0;
            }
            if (message == kJjboxPluginTrayMessage) {
              HandleTrayMessage(hwnd, lparam);
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
    event_thread_ = std::thread([this] { EventPumpLoop(); });
  }

  ~JjboxPlugin() override {
    {
      std::lock_guard<std::mutex> guard(completion_mutex_);
      shutting_down_ = true;
    }
    {
      std::lock_guard<std::mutex> guard(event_mutex_);
      event_stop_ = true;
    }
    event_cv_.notify_all();
    if (event_thread_.joinable()) event_thread_.join();
    RemoveTray();
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
  void DrainEventsFromPlatformThread() { DrainEvents(); }
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
    if (method == "tray.update") {
      UpdateTray(*payload);
      result->Success(EncodableValue(OkEnvelope(id, "{\"updated\":true}")));
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

  void UpdateTray(const std::string& payload) {
    if (view_handle_ == nullptr) return;
    HWND hwnd = GetAncestor(view_handle_, GA_ROOT);
    if (hwnd == nullptr) return;
    tray_running_ = SniffBool(payload, "running");
    const int port = SniffInt(payload, "proxyPort", 0);
    const std::string mode = SniffString(payload, "mode");
    std::wstring tooltip = tray_running_ ? L"JiejieBox - running" : L"JiejieBox - stopped";
    if (port > 0 && tray_running_) {
      tooltip += L" (";
      tooltip += std::to_wstring(port);
      tooltip += L")";
    }
    if (!mode.empty() && tray_running_) {
      tooltip += L" [" + std::wstring(mode.begin(), mode.end()) + L"]";
    }
    tray_tooltip_ = tooltip;
    if (tray_added_) {
      NOTIFYICONDATAW data = {};
      data.cbSize = sizeof(data);
      data.hWnd = hwnd;
      data.uID = 1;
      wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
      Shell_NotifyIconW(NIM_MODIFY, &data);
      return;
    }
    tray_hwnd_ = hwnd;
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(data);
    data.hWnd = hwnd;
    data.uID = 1;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    data.uCallbackMessage = kJjboxPluginTrayMessage;
    data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101));
    if (data.hIcon == nullptr) data.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcsncpy_s(data.szTip, tray_tooltip_.c_str(), _TRUNCATE);
    if (Shell_NotifyIconW(NIM_ADD, &data)) {
      tray_added_ = true;
      DebugLog("tray added hwnd=" +
               std::to_string(reinterpret_cast<uintptr_t>(hwnd)));
      NOTIFYICONDATAW version = {};
      version.cbSize = sizeof(version);
      version.hWnd = hwnd;
      version.uID = 1;
      version.uVersion = NOTIFYICON_VERSION_4;
      Shell_NotifyIconW(NIM_SETVERSION, &version);
    }
  }

  void RemoveTray() {
    if (!tray_added_ || tray_hwnd_ == nullptr) return;
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(data);
    data.hWnd = tray_hwnd_;
    data.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &data);
    tray_added_ = false;
  }

  void HandleTrayMessage(HWND hwnd, LPARAM event) {
    // NOTIFYICON_VERSION_4 reports the event in the low word of lParam.
    const UINT message = LOWORD(event);
    if (message == WM_LBUTTONUP || message == NIN_SELECT) {
      ShowWindow(hwnd, SW_SHOW);
      SetForegroundWindow(hwnd);
      return;
    }
    if (message != WM_RBUTTONUP && message != WM_CONTEXTMENU) return;
    HMENU menu = CreatePopupMenu();
    if (menu == nullptr) return;
    AppendMenuW(menu, MF_STRING, 1, L"Show JiejieBox");
    AppendMenuW(menu, MF_STRING, 2, L"Hide to tray");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 3, L"Quit");
    POINT cursor = {};
    GetCursorPos(&cursor);
    SetForegroundWindow(hwnd);
    const int command = TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x,
        cursor.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
    if (command == 1) {
      ShowWindow(hwnd, SW_SHOW);
      SetForegroundWindow(hwnd);
    } else if (command == 2) {
      ShowWindow(hwnd, SW_HIDE);
    } else if (command == 3) {
      PostMessageW(hwnd, WM_CLOSE, 0, 0);
    }
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

  // Runs off the platform thread. Polling one event at a time keeps the C++
  // side free of a JSON parser: the host returns the exact callback envelope as
  // a base64 string and Flutter's channel codec parses it on the Dart side.
  void EventPumpLoop() {
    uint64_t counter = 0;
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(event_mutex_);
        event_cv_.wait_for(lock, std::chrono::milliseconds(300),
                           [this] { return event_stop_; });
        if (event_stop_) return;
      }
      const std::string payload =
          "{\"id\":\"events-" + std::to_string(++counter) +
          "\",\"method\":\"events.poll\"}";
      std::string response;
      if (!link_->Send(payload, &response)) {
        std::unique_lock<std::mutex> lock(event_mutex_);
        event_cv_.wait_for(lock, std::chrono::milliseconds(500),
                           [this] { return event_stop_; });
        if (event_stop_) return;
        continue;
      }
      const std::string encoded = SniffString(response, "event");
      if (encoded.empty()) continue;
      std::string event = Base64Decode(encoded);
      if (event.empty()) continue;
      {
        std::lock_guard<std::mutex> guard(event_mutex_);
        pending_events_.push_back(std::move(event));
      }
      HWND target = view_handle_ != nullptr ? GetAncestor(view_handle_, GA_ROOT)
                                            : nullptr;
      if (target != nullptr) {
        PostMessageW(target, kJjboxPluginEventMessage, 0, 0);
      }
    }
  }

  void DrainEvents() {
    std::vector<std::string> ready;
    {
      std::lock_guard<std::mutex> guard(event_mutex_);
      ready.swap(pending_events_);
    }
    if (ready.empty() || !callbacks_) return;
    DebugLog("drain events=" + std::to_string(ready.size()));
    for (const std::string& event : ready) {
      callbacks_->InvokeMethod(
          "event", std::make_unique<EncodableValue>(event));
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

  std::mutex event_mutex_;
  std::condition_variable event_cv_;
  std::vector<std::string> pending_events_;
  std::thread event_thread_;
  bool event_stop_ = false;

  HWND tray_hwnd_ = nullptr;
  bool tray_added_ = false;
  bool tray_running_ = false;
  std::wstring tray_tooltip_;
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

void JjboxPluginDrainEvents() {
  if (g_plugin != nullptr) {
    g_plugin->DrainEventsFromPlatformThread();
  }
}
