import Foundation
import Libbox

/// App-side runtime subscription for the iOS/iPadOS host.
///
/// libbox runs in the Packet Tunnel extension. Its CommandServer listens on a
/// unix socket inside the App Group container; the app process opens a
/// CommandClient to the same base path and receives groups/status/connections/logs
/// as callbacks. The callbacks are turned into the runtime contract events that
/// the Dart bridge polls through `events.poll`.
final class JjboxRuntimeClient: NSObject, LibboxCommandClientHandler {
  private let lock = NSLock()
  private var client: LibboxCommandClient?
  private var events: [String] = []
  private var seq: Int64 = 0
  private var epoch = UUID().uuidString
  private var lastGroups: [[String: Any]] = []

  private let maxEvents = 4096

  var hostEpoch: String {
    lock.lock()
    defer { lock.unlock() }
    return epoch
  }

  func start() {
    lock.lock()
    if client != nil {
      lock.unlock()
      return
    }
    let options = LibboxCommandClientOptions()
    options.statusInterval = 1_000
    guard let created = LibboxNewCommandClient(self, options) else {
      lock.unlock()
      emit("runtime.error", ["code": "core_unavailable", "message": "command client is unavailable"])
      return
    }
    client = created
    lock.unlock()
    DispatchQueue.global(qos: .utility).async {
      try? created.connect()
    }
  }

  func stop() {
    lock.lock()
    let current = client
    client = nil
    lock.unlock()
    try? current?.disconnect()
  }

  func poll() -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard !events.isEmpty else { return nil }
    return events.removeFirst()
  }

  private func emit(_ type: String, _ payload: [String: Any]) {
    lock.lock()
    seq += 1
    var body = payload
    body["hostEpoch"] = epoch
    let envelope: [String: Any] = ["type": type, "seq": seq, "payload": body]
    if let data = try? JSONSerialization.data(withJSONObject: envelope),
       let text = String(data: data, encoding: .utf8) {
      events.append(text)
      if events.count > maxEvents {
        events.removeFirst(events.count - maxEvents)
      }
    }
    lock.unlock()
  }

  private func jsonValue(_ box: LibboxStringBox?) -> [String: Any]? {
    guard let text = box?.value, let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object
  }

  // MARK: - Commands

  func select(group: String, outbound: String, expectedRevision: Int64) throws -> [String: Any] {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    let box = try client.selectOutboundWithRequest(group, outboundTag: outbound, requestID: 0, expectedRevision: expectedRevision)
    return jsonValue(box) ?? ["accepted": true, "group": group, "outbound": outbound]
  }

  func urlTest(outbound: String) throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.urlTest(outbound)
  }

  func setMode(_ mode: String) throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.setClashMode(mode)
  }

  func setGroupExpand(group: String, expanded: Bool) throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.setGroupExpand(group, isExpand: expanded)
  }

  func clearLogs() throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.clearLogs()
    emit("logs.cleared", [:])
  }

  func closeConnection(id: String) throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.closeConnection(id)
  }

  func closeAllConnections() throws {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    try client.closeConnections()
  }

  func refreshProviders(tags: [String], timeoutMillis: Int64) throws -> [String: Any] {
    guard let client else { throw NSError(domain: "JiejieBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "command client is not running"]) }
    let box = try client.refreshRemoteProviders(tags.joined(separator: ","), timeoutMilliseconds: timeoutMillis)
    return jsonValue(box) ?? ["supported": false]
  }

  // MARK: - LibboxCommandClientHandler

  func clearLogs() {
    emit("logs.cleared", [:])
  }

  func connected() {
    emit("runtime.connected", [:])
  }

  func disconnected(_ message: String?) {
    emit("runtime.disconnected", ["message": message ?? ""])
  }

  func initializeClashMode(_ modeList: LibboxStringIterator?, currentMode: String?) {
    var modes: [String] = []
    if let modeList {
      while modeList.hasNext() {
        guard let mode = modeList.next() else { break }
        modes.append(mode)
      }
    }
    emit("runtime.modes", [
      "modes": modes,
      "current": currentMode ?? "",
      "available": !modes.isEmpty,
    ])
  }

  func setDefaultLogLevel(_ level: Int32) {}

  func updateClashMode(_ newMode: String?) {
    emit("runtime.modes", [
      "current": newMode ?? "",
      "available": true,
    ])
  }

  func writeConnectionEvents(_ events: LibboxConnectionEvents?) {
    guard let events else { return }
    var records: [[String: Any]] = []
    if let iterator = events.iterator() {
      while iterator.hasNext() {
        guard let event = iterator.next() else { break }
        var record: [String: Any] = [
          "type": event.type,
          "id": event.id_,
          "uplinkDelta": event.uplinkDelta,
          "downlinkDelta": event.downlinkDelta,
          "closedAt": event.closedAt,
        ]
        if let connection = event.connection {
          record["network"] = connection.network
          record["destination"] = connection.destination
          record["outbound"] = connection.outbound
          record["createdAt"] = connection.createdAt
          var chain: [String] = []
          if let iterator = connection.chain() {
            while iterator.hasNext() {
              guard let tag = iterator.next() else { break }
              chain.append(tag)
            }
          }
          record["chain"] = chain
          record["rule"] = connection.rule
        }
        records.append(record)
      }
    }
    emit("runtime.connections", [
      "reset": events.reset,
      "instanceId": events.instanceId,
      "events": records,
    ])
  }

  func writeGroups(_ message: LibboxOutboundGroupIterator?) {
    guard let message else { return }
    var groups: [[String: Any]] = []
    while message.hasNext() {
      guard let group = message.next() else { break }
      var items: [[String: Any]] = []
      if let iterator = group.getItems() {
        while iterator.hasNext() {
          guard let item = iterator.next() else { break }
          items.append([
            "tag": item.tag,
            "type": item.type,
            "urlTestTime": item.urlTestTime,
            "urlTestDelay": Int(item.urlTestDelay),
          ])
        }
      }
      groups.append([
        "tag": group.tag,
        "type": group.type,
        "selectable": group.selectable,
        "selected": group.selected,
        "expanded": group.isExpand,
        "items": items,
      ])
    }
    lock.lock()
    lastGroups = groups
    lock.unlock()
    emit("runtime.groups", ["groups": groups])
  }

  func writeLogs(_ messageList: LibboxLogIterator?) {
    guard let messageList else { return }
    while messageList.hasNext() {
      guard let entry = messageList.next() else { break }
      emit("runtime.log", [
        "level": entry.level,
        "message": redact(entry.message),
        "at": Int64(Date().timeIntervalSince1970 * 1000),
      ])
    }
  }

  func writeOutbounds(_ message: LibboxOutboundGroupItemIterator?) {}

  func writeStatus(_ message: LibboxStatusMessage?) {
    guard let message else { return }
    emit("runtime.status", [
      "serviceState": "running",
      "memoryBytes": message.memory,
      "goroutines": message.goroutines,
      "connectionsIn": message.connectionsIn,
      "connectionsOut": message.connectionsOut,
      "trafficAvailable": message.trafficAvailable,
      "uplinkBytes": message.uplink,
      "downlinkBytes": message.downlink,
      "uplinkTotalBytes": message.uplinkTotal,
      "downlinkTotalBytes": message.downlinkTotal,
      "sampledAt": Int64(Date().timeIntervalSince1970 * 1000),
    ])
  }

  private func redact(_ message: String) -> String {
    var result = message
    for key in ["password=", "token=", "uuid="] {
      var searchRange = result.startIndex..<result.endIndex
      while let range = result.range(of: key, options: [.caseInsensitive], range: searchRange) {
        let valueStart = range.upperBound
        var valueEnd = valueStart
        while valueEnd < result.endIndex, !" &;\t\n".contains(result[valueEnd]) {
          valueEnd = result.index(after: valueEnd)
        }
        result.replaceSubrange(valueStart..<valueEnd, with: "***")
        searchRange = valueEnd..<result.endIndex
        if valueStart >= result.endIndex { break }
      }
    }
    return result
  }
}
