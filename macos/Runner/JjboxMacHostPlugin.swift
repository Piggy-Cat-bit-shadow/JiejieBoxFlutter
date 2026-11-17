import AppKit
import Flutter
import Foundation

/// The macOS end of `jjbox/host`.
///
/// Two routes share this channel: a Network Extension (signed distribution) or a
/// privileged helper reached over a local socket (direct distribution). The route
/// is chosen at setup time; the channel shape never changes.
final class JjboxMacHostPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "jjbox/host",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(JjboxMacHostPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "jjbox.invoke" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let payload = call.arguments as? String else {
      result(FlutterError(code: "bad_args", message: "expected a JSON string", details: nil))
      return
    }
    if payload.contains("\"clipboard.readCandidate\"") {
      result(localClipboardEnvelope(id: Self.sniff(payload, key: "id")))
      return
    }
    let id = Self.sniff(payload, key: "id")
    if payload.contains("\"host.capabilities\"") {
      result(Self.localEnvelope(id: id, result: [
        "core": false,
        "tun": false,
        "systemProxy": false,
        "perAppProxy": false,
        "autostart": false,
        "tray": true,
        "qrCamera": false,
        "qrImageDecode": false,
        "fileImport": true,
        "clipboardWatch": true,
        "notifications": true,
        "deepLink": true,
        "memoryPressure": false,
        "serviceModes": ["proxy"],
      ]))
      return
    }
    if payload.contains("\"core.capabilities\"") {
      result(Self.localEnvelope(id: id, result: [
        "apiVersion": 0,
        "platform": "macos",
        "buildQuic": false,
        "capabilities": [],
      ]))
      return
    }
    if payload.contains("\"config.") || payload.contains("\"provider.refresh\"") {
      result(Self.localError(id: id, code: "unsupported_platform",
                             message: "the helper route is not wired and no kernel is linked"))
      return
    }
    // TODO(P1): forward to the helper socket or NETunnelProviderSession and reply
    // with the envelope. The helper answers transport_disconnected when the
    // daemon is not installed, which is exactly what the contract expects.
    result(FlutterError(code: "transport_disconnected", message: "helper route not wired yet", details: nil))
  }

  /// Clipboard reads stay local; promotion needs the Dart gate.
  private func localClipboardEnvelope(id: String) -> String {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    let likely: String
    if text.isEmpty {
      likely = "unknown"
    } else if text.hasPrefix("http://") || text.hasPrefix("https://") {
      likely = "subscription-url"
    } else if ["vless://", "vmess://", "trojan://", "ss://", "tuic://", "hysteria2://", "hy2://", "anytls://"]
      .contains(where: { text.hasPrefix($0) }) {
      likely = "share-link"
    } else if text.hasPrefix("{") {
      likely = "singbox-json"
    } else if text.hasPrefix("proxies:") {
      likely = "clash-yaml"
    } else {
      likely = "unknown"
    }
    let payload: [String: Any] = ["id": id, "ok": true, "result": ["text": text, "likely": likely]]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let encoded = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return encoded
  }

  static func localEnvelope(id: String, result: [String: Any]) -> String {
    let payload: [String: Any] = ["id": id, "ok": true, "result": result]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let encoded = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return encoded
  }

  static func localError(id: String, code: String, message: String) -> String {
    let payload: [String: Any] = [
      "id": id,
      "ok": false,
      "error": ["code": code, "message": message, "retryable": false],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let encoded = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return encoded
  }

  static func sniff(_ payload: String, key: String) -> String {
    guard let keyRange = payload.range(of: "\"\\(key)\":\"") else { return "" }
    let rest = payload[keyRange.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return "" }
    return String(rest[..<end])
  }
}