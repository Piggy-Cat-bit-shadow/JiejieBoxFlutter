import Flutter
import Foundation
import NetworkExtension
import UIKit

/// The iOS/iPadOS end of `jjbox/host`.
///
/// The containing app owns the channel and forwards envelopes to the Network
/// Extension through `NETunnelProviderSession.sendProviderMessage`, which has no
/// timeout of its own: every send here is bounded by `deadline`.
final class JjboxHostPlugin: NSObject, FlutterPlugin {
  static let commandsChannel = "jjbox/host"
  static let callbacksChannel = "jjbox/host/callback"
  static let invokeMethod = "jjbox.invoke"

  private var callbacks: FlutterMethodChannel?
  private var session: NETunnelProviderSession?
  private let deadline: TimeInterval = 15

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = JjboxHostPlugin()
    let commands = FlutterMethodChannel(
      name: commandsChannel,
      binaryMessenger: registrar.messenger()
    )
    instance.callbacks = FlutterMethodChannel(
      name: callbacksChannel,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: commands)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == Self.invokeMethod else {
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
    send(payload: payload, result: result)
  }

  /// One request, one response. A nil reply from `sendProviderMessage` means the
  /// message never reached the extension, so it becomes a typed transport error
  /// rather than an empty result.
  private func send(payload: String, result: @escaping FlutterResult) {
    guard let session = activeSession() else {
      result(FlutterError(code: "transport_disconnected", message: "no tunnel session", details: nil))
      return
    }
    guard let data = payload.data(using: .utf8) else {
      result(FlutterError(code: "bad_args", message: "payload is not UTF-8", details: nil))
      return
    }
    var finished = false
    let lock = NSLock()
    func finish(_ value: Any?) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      result(value)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
      finish(FlutterError(code: "timeout", message: "extension did not answer", details: nil))
    }
    do {
      try session.sendProviderMessage(data) { response in
        guard let response = response, let text = String(data: response, encoding: .utf8) else {
          finish(FlutterError(code: "transport_disconnected", message: "extension returned no reply", details: nil))
          return
        }
        finish(text)
      }
    } catch {
      finish(FlutterError(code: "transport_disconnected", message: "\(error)", details: nil))
    }
  }

  /// Clipboard reads stay local to the app process; promotion needs the Dart gate.
  private func localClipboardEnvelope(id: String) -> String {
    let text = UIPasteboard.general.string ?? ""
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

  static func sniff(_ payload: String, key: String) -> String {
    guard let keyRange = payload.range(of: "\"\\(key)\":\"") else { return "" }
    let rest = payload[keyRange.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return "" }
    return String(rest[..<end])
  }

  /// Only a running, owned tunnel can answer bridge calls.
  private func activeSession() -> NETunnelProviderSession? {
    if let session = session {
      return session
    }
    return nil
  }
}
