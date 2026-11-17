import Foundation
import NetworkExtension

/// The Network Extension side: the only process on iOS/iPadOS that may run the
/// core. It answers envelopes from the app on `handleAppMessage` and owns the
/// tunnel settings.
///
/// Memory budget: this process has 45-50 MB. Parsing, provider refresh and
/// `config.check` stay in the app; the envelope's `config.apply` carries the
/// already-validated document.
final class JjboxPacketTunnelProvider: NEPacketTunnelProvider {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var appliedRevision: String?

  /// Set by libbox's CommandServer handler; the shell answers before the core is
  /// linked so the channel works end to end on day one.
  private var coreLinked: Bool { false }

  override func startTunnel(options: [String: NSObject]?) async throws {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = 9000
    let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4
    settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])
    try await setTunnelNetworkSettings(settings)
    // TODO(P1): libbox.Setup + CommandServer.StartOrReloadService(configContent).
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    lock.lock()
    generation &+= 1
    lock.unlock()
    // TODO(P1): CommandServer.CloseService() then Close().
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let text = String(data: messageData, encoding: .utf8) else {
      completionHandler?(Self.errorEnvelope(code: "invalid_argument", message: "not UTF-8"))
      return
    }
    lock.lock()
    generation &+= 1
    let current = generation
    lock.unlock()
    let reply = handle(envelope: text, generation: current)
    completionHandler?(reply.data(using: .utf8))
  }

  /// Synchronous by design: the app already bounded the wait, and a half-applied
  /// config is worse than a typed error.
  private func handle(envelope: String, generation: UInt64) -> String {
    guard coreLinked else {
      if envelope.contains("service.status") {
        return Self.okEnvelope(
          result: [
            "state": "idle",
            "revision": 0,
            "mode": "vpn",
            "tunActive": true,
            "permission": "granted",
          ]
        )
      }
      if envelope.contains("host.capabilities") {
        return Self.okEnvelope(result: [
          "core": false,
          "tun": true,
          "systemProxy": false,
          "perAppProxy": true,
          "autostart": false,
          "tray": false,
          "qrCamera": false,
          "qrImageDecode": false,
          "fileImport": true,
          "clipboardWatch": true,
          "notifications": true,
          "deepLink": true,
          "memoryPressure": true,
          "serviceModes": ["vpn"],
        ])
      }
      if envelope.contains("core.capabilities") {
        return Self.okEnvelope(result: [
          "apiVersion": 0,
          "platform": "ios",
          "buildQuic": false,
          "capabilities": [],
        ])
      }
      if envelope.contains("provider.refresh") {
        return Self.okEnvelope(result: [
          "supported": false,
          "refreshed": [],
          "failed": [String: String](),
          "durationMillis": 0,
        ])
      }
      // config.check/format/preview need the core in this process; without it the
      // answer is a capability answer, not "the core is stopped".
      return Self.errorEnvelope(code: "unsupported_platform", message: "libbox is not linked into the extension")
    }
    return Self.errorEnvelope(code: "unsupported_platform", message: "not implemented")
  }

  static func okEnvelope(result: [String: Any]) -> String {
    let payload: [String: Any] = ["ok": true, "result": result]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return text
  }

  static func errorEnvelope(code: String, message: String, retryable: Bool = false) -> String {
    let payload: [String: Any] = [
      "ok": false,
      "error": ["code": code, "message": message, "retryable": retryable],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return text
  }
}
