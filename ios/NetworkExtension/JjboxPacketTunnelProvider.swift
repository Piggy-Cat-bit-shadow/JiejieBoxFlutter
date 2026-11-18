import Foundation
import Libbox
import Network
import NetworkExtension

/// The iOS/iPadOS/macOS Network Extension side of JiejieBox.
///
/// This is intentionally a small Tier-1 host: libbox runs in this process, the
/// app talks to it through `NETunnelProviderSession`, and the provider hands the
/// TUN descriptor installed by the system to libbox. Profile storage and config
/// validation stay in the app.
final class JjboxPacketTunnelProvider: NEPacketTunnelProvider {
  private var commandServer: LibboxCommandServer?
  private var configContent: String?
  private var running = false
  private var networkSettings: NEPacketTunnelNetworkSettings?
  private let lock = NSLock()

  override func startTunnel(options: [String: NSObject]?) async throws {
    let content = (options?["configContent"] as? String)
      ?? (protocolConfiguration.providerConfiguration?["configContent"] as? String)
    guard let content, !content.isEmpty else {
      throw NSError(
        domain: "JiejieBox",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "missing configContent"]
      )
    }
    configContent = content

    let setup = LibboxSetupOptions()
    let base = Self.supportDirectory()
    setup.basePath = base
    setup.workingPath = base + "/work"
    setup.tempPath = base + "/temp"
    setup.logMaxLines = 2000
    setup.debug = false
    setup.crashReportSource = "JiejieBox-NE"
    setup.appVersion = "0.1.0"
    setup.appMarketingVersion = "0.1.0"
    var setupError: NSError?
    _ = LibboxSetup(setup, &setupError)
    if let setupError { throw setupError }

    var serverError: NSError?
    guard let server = LibboxNewCommandServer(self, self, &serverError) else {
      throw serverError ?? NSError(
        domain: "JiejieBox",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "LibboxNewCommandServer returned nil"]
      )
    }
    commandServer = server
    do {
      try server.start()
    } catch {
      commandServer = nil
      throw error
    }
    // This call synchronously reaches openTun, which installs the network
    // settings and returns the descriptor the system created for this tunnel.
    _ = server.applyServiceChangeReport(content, options: LibboxOverrideOptions())
    running = true
  }

  override func stopTunnel(with reason: NEProviderStopReason) async {
    lock.lock()
    running = false
    lock.unlock()
    commandServer?.closeService()
    commandServer?.close()
    commandServer = nil
    networkSettings = nil
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let object = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
          let method = object["method"] as? String,
          let id = object["id"] as? String else {
      completionHandler?(Self.errorEnvelope(id: "", code: "invalid_argument", message: "malformed request"))
      return
    }
    let args = object["args"] as? [String: Any] ?? [:]
    switch method {
    case "service.stop":
      commandServer?.closeService()
      running = false
      completionHandler?(Self.okEnvelope(id: id, result: ["accepted": true]))
    case "service.status":
      completionHandler?(Self.okEnvelope(id: id, result: [
        "state": running ? "running" : "stopped",
        "revision": 0,
        "mode": "vpn",
        "tunActive": running,
        "permission": "granted",
      ]))
    case "config.check":
      let content = args["content"] as? String ?? ""
      var error: NSError?
      let ok = LibboxCheckConfig(content, &error)
      if ok {
        completionHandler?(Self.okEnvelope(id: id, result: ["ok": true]))
      } else {
        completionHandler?(Self.errorEnvelope(id: id, code: "core_rejected_config", message: error?.localizedDescription ?? "invalid config"))
      }
    case "service.apply":
      guard let content = args["content"] as? String else {
        completionHandler?(Self.errorEnvelope(id: id, code: "invalid_argument", message: "content is required"))
        return
      }
      _ = commandServer?.applyServiceChangeReport(content, options: LibboxOverrideOptions())
      configContent = content
      completionHandler?(Self.okEnvelope(id: id, result: ["applied": true]))
    default:
      completionHandler?(Self.errorEnvelope(id: id, code: "unsupported_platform", message: "unknown extension method \(method)"))
    }
  }

  // MARK: - Networking

  private static func supportDirectory() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("JiejieBox/network-extension", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }

  private static func okEnvelope(id: String, result: [String: Any]) -> Data {
    let payload: [String: Any] = ["id": id, "ok": true, "result": result]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  private static func errorEnvelope(id: String, code: String, message: String) -> Data {
    let payload: [String: Any] = [
      "id": id,
      "ok": false,
      "error": ["code": code, "message": message, "retryable": false],
    ]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }
}

// MARK: - LibboxPlatformInterfaceProtocol

extension JjboxPacketTunnelProvider: LibboxPlatformInterfaceProtocol {
  func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    guard let options, let ret0_ else { throw NSError(domain: "JiejieBox", code: 1) }
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    var mtu = Int(options.getMTU())
    if mtu < 1280 || mtu > 9000 { mtu = 9000 }
    settings.mtu = NSNumber(value: mtu)
    if options.getAutoRoute() {
      var addresses: [String] = []
      var masks: [String] = []
      if let iterator = options.getInet4Address() {
        while iterator.hasNext() {
          guard let prefix = iterator.next(), let address = prefix.address()?.value,
                let mask = prefix.mask()?.value else { continue }
          addresses.append(address)
          masks.append(mask)
        }
      }
      if !addresses.isEmpty {
        let ipv4 = NEIPv4Settings(addresses: addresses, subnetMasks: masks)
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
      }
      var dnsServers: [String] = []
      if let iterator = try? options.getDNSServerAddress() {
        while iterator.hasNext() {
          if let value = iterator.next(), !value.isEmpty { dnsServers.append(value) }
        }
      }
      if !dnsServers.isEmpty {
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
      }
    }
    networkSettings = settings
    try runBlocking { try await self.setTunnelNetworkSettings(settings) }
    if let fd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
      ret0_.pointee = fd
      return
    }
    let fd = LibboxGetTunnelFileDescriptor()
    guard fd != -1 else {
      throw NSError(domain: "JiejieBox", code: 2, userInfo: [NSLocalizedDescriptionKey: "TUN descriptor is missing"])
    }
    ret0_.pointee = fd
  }

  func usePlatformAutoDetectControl() -> Bool { false }
  func autoDetectControl(_ fd: Int32) throws {}
  func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection owner is not available"])
  }
  func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
    listener?.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
    listener?.updateNetworkPath("")
  }
  func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
  func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol { EmptyInterfaceIterator() }
  func underNetworkExtension() -> Bool { true }
  func includeAllNetworks() -> Bool { false }
  func clearDNSCache() {}
  func readWIFIState() -> LibboxWIFIState? { nil }
  func sendNotification(_ notification: LibboxNotification?) throws {}
  func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
  func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
  func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
  func registerMyInterface(_ name: String?) {}
  func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
  func systemCertificates() -> LibboxStringIteratorProtocol? { nil }
  func usePlatformShell() -> Bool { false }
  func checkPlatformShell() throws {}
  func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "shell is not supported"])
  }
  func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "user lookup is not supported"])
  }
  func lookupSFTPServer(_ error: NSErrorPointer) -> String { "" }
  func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { "" }
  func tailscaleHostname() -> String { "" }
  func usePlatformBridge() -> Bool { false }
  func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "bridge is not supported"])
  }
  func usePlatformAutoRedirect() -> Bool { false }
  func createAutoRedirect(_ data: Data?, handler: LibboxAutoRedirectHandlerProtocol?) throws -> LibboxAutoRedirectSessionProtocol {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "auto redirect is not supported"])
  }
}

extension JjboxPacketTunnelProvider: LibboxCommandServerHandlerProtocol {
  func serviceStop() throws {}
  func serviceReload() throws {}
  func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
    let status = LibboxSystemProxyStatus()
    status.available = false
    status.enabled = false
    return status
  }
  func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
  func triggerNativeCrash() throws {}
  func writeDebugMessage(_ message: String?) {}
  func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "ssh agent is not supported"])
  }
}

private final class EmptyInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
  func hasNext() -> Bool { false }
  func next() -> LibboxNetworkInterface? { nil }
}

private func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  var result: Result<T, Error>?
  Task {
    do {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    semaphore.signal()
  }
  semaphore.wait()
  switch result {
  case .success(let value): return value
  case .failure(let error): throw error
  case .none:
    throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "operation did not complete"])
  }
}
