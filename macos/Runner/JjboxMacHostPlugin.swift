import AppKit
import Darwin
import Flutter
import Foundation

/// The macOS end of `jjbox/host`.
///
/// Two routes share this channel: a Network Extension (signed distribution) or a
/// privileged helper reached over a local Unix socket (direct distribution). This
/// plugin forwards every host method to the helper socket when it is present; the
/// local answers below are the honest fallback when the helper is not installed.
final class JjboxMacHostPlugin: NSObject, FlutterPlugin {
  private let helperProcess: HelperProcess
  private let helper: HelperSocketClient

  override init() {
    let process = HelperProcess()
    helperProcess = process
    helper = HelperSocketClient(socketPath: process.socketPath)
    super.init()
    process.start()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    helperProcess.stop()
  }

  @objc private func applicationWillTerminate() {
    helperProcess.stop()
  }

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
    let isCapabilities = payload.contains("\"host.capabilities\"") ||
      payload.contains("\"core.capabilities\"")
    if isCapabilities {
      if let reply = helper.request(payload) {
        result(reply)
      } else if helperProcess.hasHelper {
        // A bundled helper is starting. Returning the local core:false answer
        // here would be cached by the one-shot runtime probe forever, so make
        // the probe retry instead.
        result(Self.localError(
          id: id,
          code: "transport_disconnected",
          message: "the macOS core helper is starting"
        ))
      } else {
        result(Self.localEnvelope(id: id, result: Self.localCapabilities(payload)))
      }
      return
    }

    // The helper owns the real kernel, profile transaction and system integration.
    // When it is absent, say transport_disconnected instead of pretending the
    // command failed inside the core.
    if let reply = helper.request(payload) {
      result(reply)
    } else if payload.contains("\"config.") || payload.contains("\"provider.refresh\"") {
      result(Self.localError(
        id: id,
        code: "core_unavailable",
        message: "the macOS helper is not reachable"
      ))
    } else {
      result(Self.localError(
        id: id,
        code: "transport_disconnected",
        message: "the macOS helper socket is not reachable"
      ))
    }
  }

  private static func localCapabilities(_ payload: String) -> [String: Any] {
    if payload.contains("\"core.capabilities\"") {
      return [
        "apiVersion": 0,
        "platform": "macos",
        "buildQuic": false,
        "capabilities": [],
      ]
    }
    return [
      "core": false,
      "tun": false,
      "systemProxy": false,
      "perAppProxy": false,
      "autostart": false,
      "tray": false,
      "qrCamera": false,
      "qrImageDecode": false,
      "fileImport": false,
      "clipboardWatch": true,
      "notifications": false,
      "deepLink": false,
      "events": false,
      "memoryPressure": false,
      "serviceModes": ["proxy"],
    ]
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

/// Owns the bundled Go helper that links libbox. The helper is proxy-only (no
/// root/TUN), and the app must not silently pretend it is present when the
/// bundle is missing.
final class HelperProcess {
  let socketPath: String
  private let executable: URL?
  private var process: Process?
  private(set) var failed = false

  var hasHelper: Bool { executable != nil }

  init() {
    let environment = ProcessInfo.processInfo.environment
    if let external = environment["JJBOX_HELPER_SOCKET"], !external.isEmpty {
      socketPath = external
      executable = nil
      return
    }
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first?.appendingPathComponent("JiejieBox/host", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: support ?? URL(fileURLWithPath: NSTemporaryDirectory()),
      withIntermediateDirectories: true
    )
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/jjbox-core-helper")
      .path
    let configured = environment["JJBOX_HELPER_EXE"] ?? ""
    let candidate = configured.isEmpty ? bundled : configured
    if FileManager.default.isExecutableFile(atPath: candidate) {
      executable = URL(fileURLWithPath: candidate)
    } else {
      executable = nil
    }
    socketPath = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("jjbox-\(getpid()).sock")
  }

  func start() {
    guard let executable, process == nil else { return }
    let data = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first?.appendingPathComponent("JiejieBox/host", isDirectory: true)
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = executable
    task.arguments = [
      "--socket", socketPath,
      "--data", data.path,
      "--parent-pid", String(getpid()),
    ]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    task.terminationHandler = { [weak self] _ in
      self?.failed = true
    }
    do {
      try task.run()
      process = task
    } catch {
      failed = true
    }
  }

  func stop() {
    process?.terminate()
    process = nil
  }
}

/// Line-delimited JSON over a Unix domain socket. The helper protocol is the same
/// envelope the Windows host uses; only the transport differs.
final class HelperSocketClient {
  private let socketPath: String

  init(socketPath: String? = nil) {
    if let socketPath, !socketPath.isEmpty {
      self.socketPath = socketPath
      return
    }
    let environment = ProcessInfo.processInfo.environment["JJBOX_HELPER_SOCKET"]
    if let environment, !environment.isEmpty {
      socketPath = environment
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      socketPath = support?
        .appendingPathComponent("JiejieBox", isDirectory: true)
        .appendingPathComponent("helper.sock")
        .path ?? "/tmp/jiejiebox-helper.sock"
    }
  }

  func request(_ envelope: String, timeout: TimeInterval = 20) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      return nil
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.initializeMemory(as: UInt8.self, repeating: 0)
      socketPath.withCString { source in
        strncpy(raw.bindMemory(to: CChar.self).baseAddress!, source, raw.count - 1)
      }
    }

    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return nil }

    var request = Data((envelope + "\n").utf8)
    let sent: Int = request.withUnsafeMutableBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if written <= 0 { return -1 }
        offset += written
      }
      return offset
    }
    guard sent == request.count else { return nil }

    var buffer = [UInt8](repeating: 0, count: 65536)
    var response = Data()
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count <= 0 { break }
      response.append(buffer, count: count)
      if response.contains(0x0A) { break }
      if response.count > 8 * 1024 * 1024 { return nil }
    }
    guard let text = String(data: response, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)
  }
}
