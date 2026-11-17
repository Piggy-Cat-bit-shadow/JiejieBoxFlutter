// The Flutter Windows end of `jjbox/host`. It is a transport, not a policy layer:
// the JSON envelope goes to the Go host process byte for byte, and callbacks come
// back on `jjbox/host/callback`.
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

#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

using flutter::EncodableValue;

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

bool WriteAll(HANDLE pipe, const char* data, DWORD length) {
  DWORD written = 0;
  while (written < length) {
    if (!WriteFile(pipe, data + written, length - written, &written, nullptr)) {
      return false;
    }
  }
  return true;
}

bool ReadAll(HANDLE pipe, char* data, DWORD length) {
  DWORD read = 0;
  while (read < length) {
    DWORD step = 0;
    if (!ReadFile(pipe, data + read, length - read, &step, nullptr)) {
      return false;
    }
    if (step == 0) return false;
    read += step;
  }
  return true;
}

class JjboxPlugin;

// One connection, one reader thread. The bridge is request/response per socket,
// so the mutex only serialises a write with its matching read.
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
      Close();
      return false;
    }
    jjbox::FrameHeader reply{0, 0};
    if (!ReadAll(pipe_, reinterpret_cast<char*>(&reply), sizeof(reply))) {
      Close();
      return false;
    }
    if (reply.length > jjbox::kMaxPayloadBytes) {
      Close();
      return false;
    }
    response->resize(reply.length);
    if (reply.length > 0 && !ReadAll(pipe_, response->data(), reply.length)) {
      Close();
      return false;
    }
    return true;
  }

  void Close() {
    std::lock_guard<std::mutex> guard(write_mutex_);
    if (pipe_ != INVALID_HANDLE_VALUE) {
      CloseHandle(pipe_);
      pipe_ = INVALID_HANDLE_VALUE;
    }
  }

 private:
  bool Ensure() {
    if (pipe_ != INVALID_HANDLE_VALUE) return true;
    pipe_ = CreateFileW(PipeName().c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                        nullptr, OPEN_EXISTING, 0, nullptr);
    return pipe_ != INVALID_HANDLE_VALUE;
  }

  JjboxPlugin* owner_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  std::mutex write_mutex_;
};

class JjboxPlugin : public flutter::Plugin {
 public:
  explicit JjboxPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), link_(new HostLink(this)) {
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
    if (link_) link_->Close();
  }

  // Called from the reader thread once the read loop exists. The frame must reach
  // the platform thread before it touches the messenger; the exact runner accessor
  // has to be checked against the 3.47.6 Windows embedder headers on first compile
  // (this file is authored, not yet compiled on this host).
  void Deliver(const std::string& frame) {
    // TODO(P1): post to the platform thread via PluginRegistrarWindows, then
    // callbacks_->InvokeMethod("event", ...).
    pending_.push_back(frame);
  }

 private:
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
    std::string response;
    if (!link_->Send(*payload, &response)) {
      // The host is not there: the Dart side turns this into core_unavailable or
      // transport_disconnected and asks for service.status after reconnecting.
      result->Error("transport_unavailable", "jjbox host pipe is not reachable");
      return;
    }
    result->Success(EncodableValue(response));
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<HostLink> link_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> commands_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> callbacks_;
  std::vector<std::string> pending_;
};


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

std::string ErrorEnvelope(const std::string& id, const std::string& code,
                          const std::string& message, bool retryable) {
  return "{\"id\":\"" + JsonEscape(id) + "\",\"ok\":false,\"error\":{\"code\":\"" +
         JsonEscape(code) + "\",\"message\":\"" + JsonEscape(message) +
         "\",\"retryable\":" + (retryable ? "true" : "false") + "}}";
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

}  // namespace

void JjboxPluginRegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<JjboxPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}
