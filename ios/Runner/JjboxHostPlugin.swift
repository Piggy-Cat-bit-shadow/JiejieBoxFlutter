import CryptoKit
import Flutter
import Foundation
import Libbox
import NetworkExtension
import UIKit

/// The iOS/iPadOS end of `jjbox/host`.
///
/// Tier 1: profiles live in the App Group, config validation runs in the app
/// process, and libbox runs only inside the Packet Tunnel extension. The app
/// starts the tunnel with the selected document in `startVPNTunnel(options:)`.
final class JjboxHostPlugin: NSObject, FlutterPlugin {
  private let store = ProfileStore()
  private var manager: NETunnelProviderManager?
  private var callbacks: FlutterMethodChannel?

  override init() {
    super.init()
    Self.setupLibbox()
  }

  private static func setupLibbox() {
    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.jiejiebox.app"
    )
    let base = (group ?? FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
      .appendingPathComponent("JiejieBox/core", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let options = LibboxSetupOptions()
    options.basePath = base.path
    options.workingPath = base.appendingPathComponent("work").path
    options.tempPath = base.appendingPathComponent("temp").path
    options.logMaxLines = 1000
    var error: NSError?
    _ = LibboxSetup(options, &error)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = JjboxHostPlugin()
    let commands = FlutterMethodChannel(
      name: "jjbox/host",
      binaryMessenger: registrar.messenger()
    )
    instance.callbacks = FlutterMethodChannel(
      name: "jjbox/host/callback",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: commands)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "jjbox.invoke" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let payload = call.arguments as? String,
          let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = object["method"] as? String,
          let id = object["id"] as? String else {
      result(Self.errorEnvelope("", "invalid_argument", "malformed request"))
      return
    }
    let args = object["args"] as? [String: Any] ?? [:]
    if method == "clipboard.readCandidate" {
      result(clipboardEnvelope(id: id))
      return
    }
    if method == "host.capabilities" {
      result(Self.okEnvelope(id: id, result: [
        "core": true,
        "tun": true,
        "systemProxy": false,
        "perAppProxy": false,
        "autostart": false,
        "tray": false,
        "qrCamera": false,
        "qrImageDecode": false,
        "fileImport": true,
        "clipboardWatch": true,
        "notifications": false,
        "deepLink": false,
        "events": false,
        "memoryPressure": false,
        "serviceModes": ["vpn"],
      ]))
      return
    }
    if method == "core.capabilities" {
      result(Self.okEnvelope(id: id, result: [
        "apiVersion": 4,
        "buildId": NSNull(),
        "buildQuic": true,
        "platform": "ios",
        "version": LibboxVersion(),
        "goVersion": LibboxGoVersion(),
        "capabilities": [],
      ]))
      return
    }
    if method == "host.setup" {
      result(Self.okEnvelope(id: id, result: [:]))
      return
    }
    if method == "host.shutdown" {
      manager?.connection.stopVPNTunnel()
      result(Self.okEnvelope(id: id, result: [:]))
      return
    }
    if method == "service.start" {
      startTunnel(args: args, id: id, result: result)
      return
    }
    if method == "service.stop" {
      manager?.connection.stopVPNTunnel()
      result(Self.okEnvelope(id: id, result: ["accepted": true, "revision": args["revision"] ?? 0]))
      return
    }
    if method == "service.status" {
      result(Self.okEnvelope(id: id, result: statusPayload()))
      return
    }
    if method == "service.apply" {
      applyProfile(args: args, id: id, result: result)
      return
    }
    if method == "config.check" {
      let content = Self.base64String(args["content"] as? String) ?? ""
      var error: NSError?
      if LibboxCheckConfig(content, &error) {
        result(Self.okEnvelope(id: id, result: ["ok": true, "normalizedKind": "singbox-json"]))
      } else {
        result(Self.errorEnvelope(id, "core_rejected_config", error?.localizedDescription ?? "invalid config"))
      }
      return
    }
    if method == "config.format" {
      let content = args["content"] as? String ?? ""
      var error: NSError?
      guard let formatted = LibboxFormatConfig(content, &error) else {
        result(Self.errorEnvelope(id, "core_rejected_config", error?.localizedDescription ?? "format failed"))
        return
      }
      result(Self.okEnvelope(id: id, result: ["content": Self.base64FromString(formatted.value ?? "")]))
      return
    }
    if method == "config.preview" {
      let content = args["content"] as? String ?? ""
      var error: NSError?
      guard let preview = LibboxParsePreview(content, &error) else {
        result(Self.errorEnvelope(id, "invalid_argument", error?.localizedDescription ?? "preview failed"))
        return
      }
      result(Self.okEnvelope(id: id, result: ["preview": preview.value ?? "{}"]))
      return
    }
    if method.hasPrefix("profile.") {
      handleProfile(method: method, args: args, id: id, result: result)
      return
    }
    if method == "provider.refresh" {
      result(Self.okEnvelope(id: id, result: [
        "supported": false, "refreshed": [], "failed": [:], "durationMillis": 0,
      ]))
      return
    }
    if method == "app.autoLaunchStatus" {
      result(Self.okEnvelope(id: id, result: ["enabled": false]))
      return
    }
    if method == "tray.update" {
      result(Self.okEnvelope(id: id, result: ["updated": false]))
      return
    }
    result(Self.errorEnvelope(id, "unsupported_platform", "unknown method \(method)"))
  }

  private func startTunnel(args: [String: Any], id: String, result: @escaping FlutterResult) {
    Task {
      do {
        let config: String
        if let inline = args["config"] as? String, !inline.isEmpty {
          config = inline
        } else if let profileId = args["profileId"] as? String {
          guard let profile = store.read(profileId) else {
            result(Self.errorEnvelope(id, "profile_not_found", "profile not found"))
            return
          }
          config = profile.content
        } else {
          result(Self.errorEnvelope(id, "invalid_argument", "no config or profileId"))
          return
        }
        var error: NSError?
        if !LibboxCheckConfig(config, &error) {
          result(Self.errorEnvelope(id, "core_rejected_config", error?.localizedDescription ?? "invalid config"))
          return
        }
        let manager = try await loadManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
          ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.jiejiebox.app.tunnel"
        proto.serverAddress = "jiejiebox"
        proto.providerConfiguration = ["configContent": config]
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel(options: ["configContent": config as NSObject])
        self.manager = manager
        result(Self.okEnvelope(id: id, result: [
          "accepted": true,
          "revision": args["revision"] ?? 0,
        ]))
      } catch {
        result(Self.errorEnvelope(id, "core_start_failed", error.localizedDescription))
      }
    }
  }

  private func applyProfile(args: [String: Any], id: String, result: @escaping FlutterResult) {
    guard let profileId = args["id"] as? String, let profile = store.read(profileId) else {
      result(Self.errorEnvelope(id, "profile_not_found", "profile not found"))
      return
    }
    var error: NSError?
    if !LibboxCheckConfig(profile.content, &error) {
      result(Self.errorEnvelope(id, "core_rejected_config", error?.localizedDescription ?? "invalid config"))
      return
    }
    Task {
      do {
        let manager = try await loadManager()
        if manager.connection.status == .connected,
           let session = manager.connection as? NETunnelProviderSession {
          let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": "service.apply",
            "args": ["content": profile.content],
          ]
          let data = try JSONSerialization.data(withJSONObject: request)
          _ = try await send(session: session, data: data)
          self.manager = manager
          result(Self.okEnvelope(id: id, result: ["applied": true]))
        } else {
          result(Self.okEnvelope(id: id, result: ["applied": true]))
        }
      } catch {
        result(Self.errorEnvelope(id, "core_start_failed", error.localizedDescription))
      }
    }
  }

  private func statusPayload() -> [String: Any] {
    let state: String
    switch manager?.connection.status {
    case .connected: state = "running"
    case .connecting, .reasserting: state = "starting"
    case .disconnecting: state = "stopping"
    default: state = "stopped"
    }
    return [
      "state": state,
      "revision": 0,
      "mode": "vpn",
      "tunActive": state == "running",
      "permission": "granted",
    ]
  }

  private func loadManager() async throws -> NETunnelProviderManager {
    if let manager { return manager }
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    if let existing = managers.first {
      manager = existing
      return existing
    }
    let created = NETunnelProviderManager()
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = "com.jiejiebox.app.tunnel"
    proto.serverAddress = "jiejiebox"
    created.protocolConfiguration = proto
    created.isEnabled = true
    try await created.saveToPreferences()
    try await created.loadFromPreferences()
    manager = created
    return created
  }

  private func send(session: NETunnelProviderSession, data: Data) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(data) { response in
          continuation.resume(returning: response)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func handleProfile(
    method: String,
    args: [String: Any],
    id: String,
    result: @escaping FlutterResult
  ) {
    switch method {
    case "profile.list":
      let items = store.list().map { profile -> [String: Any] in
        [
          "id": profile.id,
          "label": profile.label,
          "kind": profile.kind,
          "revision": profile.revision,
          "updatedAtMillis": profile.updatedAtMillis,
          "source": "local",
        ]
      }
      result(Self.okEnvelope(id: id, result: ["items": items]))
    case "profile.read":
      guard let profileId = args["id"] as? String, let profile = store.read(profileId) else {
        result(Self.errorEnvelope(id, "profile_not_found", "profile not found"))
        return
      }
      result(Self.okEnvelope(id: id, result: [
        "id": profile.id,
        "content": Self.base64FromString(profile.content),
        "revision": profile.revision,
        "updatedAtMillis": profile.updatedAtMillis,
      ]))
    case "profile.write":
      guard let content64 = args["content"] as? String,
            let contentData = Data(base64Encoded: content64),
            let content = String(data: contentData, encoding: .utf8) else {
        result(Self.errorEnvelope(id, "invalid_argument", "content must be base64"))
        return
      }
      let validate = args["validate"] as? Bool ?? true
      if validate {
        var error: NSError?
        if !LibboxCheckConfig(content, &error) {
          result(Self.errorEnvelope(id, "core_rejected_config", error?.localizedDescription ?? "invalid config"))
          return
        }
      }
      let profile = store.write(
        id: args["id"] as? String,
        label: args["label"] as? String ?? "Imported",
        kind: args["kind"] as? String ?? "local",
        content: content
      )
      result(Self.okEnvelope(id: id, result: [
        "id": profile.id,
        "revision": profile.revision,
        "bytes": content.utf8.count,
        "validated": validate,
      ]))
    case "profile.delete":
      if let profileId = args["id"] as? String {
        store.delete(profileId)
      }
      result(Self.okEnvelope(id: id, result: [:]))
    case "profile.restore":
      result(Self.errorEnvelope(id, "unsupported_platform", "restore is not implemented on iOS"))
    default:
      result(Self.errorEnvelope(id, "unsupported_platform", "unknown profile method"))
    }
  }

  private func clipboardEnvelope(id: String) -> String {
    let text = UIPasteboard.general.string ?? ""
    let payload: [String: Any] = [
      "id": id, "ok": true,
      "result": ["text": text, "likely": Self.classifyClipboard(text)],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else {
      return Self.errorEnvelope(id, "internal", "encode failed")
    }
    return text
  }

  private static func classifyClipboard(_ text: String) -> String {
    if text.isEmpty { return "unknown" }
    if text.hasPrefix("http://") || text.hasPrefix("https://") { return "subscription-url" }
    if ["vless://", "vmess://", "trojan://", "ss://", "tuic://", "hysteria2://", "hy2://", "anytls://"]
      .contains(where: { text.hasPrefix($0) }) { return "share-link" }
    if text.hasPrefix("{") { return "singbox-json" }
    if text.hasPrefix("proxies:") { return "clash-yaml" }
    return "unknown"
  }

  private static func base64String(_ value: String?) -> String? {
    guard let value, let data = Data(base64Encoded: value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func base64FromString(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
  }

  static func okEnvelope(id: String, result: [String: Any]) -> String {
    let payload: [String: Any] = ["id": id, "ok": true, "result": result]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else {
      return errorEnvelope(id, "internal", "encode failed")
    }
    return text
  }

  static func errorEnvelope(_ id: String, _ code: String, _ message: String) -> String {
    let payload: [String: Any] = [
      "id": id,
      "ok": false,
      "error": ["code": code, "message": message, "retryable": false],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else {
      return "{\"ok\":false,\"error\":{\"code\":\"internal\",\"message\":\"encode failed\",\"retryable\":false}}"
    }
    return text
  }
}

private struct StoredProfile {
  let id: String
  let label: String
  let kind: String
  let revision: String
  let updatedAtMillis: Int64
  let content: String
}

private final class ProfileStore {
  private let directory: URL

  init() {
    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.jiejiebox.app"
    )
    let base = group ?? FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    directory = base.appendingPathComponent("JiejieBox/profiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func list() -> [StoredProfile] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .compactMap { readFile($0) }
      .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
  }

  func read(_ id: String) -> StoredProfile? {
    readFile(directory.appendingPathComponent("\(id).json"))
  }

  func write(id: String?, label: String, kind: String, content: String) -> StoredProfile {
    let profileId = id ?? "p\(Int64(Date().timeIntervalSince1970 * 1000))"
    let revision = Self.sha256(content)
    let profile = StoredProfile(
      id: profileId,
      label: label,
      kind: kind,
      revision: revision,
      updatedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
      content: content
    )
    let payload: [String: Any] = [
      "id": profile.id,
      "label": profile.label,
      "kind": profile.kind,
      "revision": profile.revision,
      "updatedAtMillis": profile.updatedAtMillis,
      "content": profile.content,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      try? data.write(to: directory.appendingPathComponent("\(profile.id).json"), options: .atomic)
    }
    return profile
  }

  func delete(_ id: String) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
  }

  private func readFile(_ url: URL) -> StoredProfile? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String,
          let content = object["content"] as? String else { return nil }
    return StoredProfile(
      id: id,
      label: object["label"] as? String ?? "Imported",
      kind: object["kind"] as? String ?? "local",
      revision: object["revision"] as? String ?? Self.sha256(content),
      updatedAtMillis: (object["updatedAtMillis"] as? NSNumber)?.int64Value
        ?? Int64(Date().timeIntervalSince1970 * 1000),
      content: content
    )
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
