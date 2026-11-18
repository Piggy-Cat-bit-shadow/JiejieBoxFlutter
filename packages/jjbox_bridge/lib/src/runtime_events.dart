/// Typed models for the runtime data bridge (RUNTIME_CONTRACT v1).
///
/// The host pushes `HostCallback`s of types `runtime.status`, `runtime.groups`,
/// `runtime.log`, `runtime.connections`, `runtime.modes` and `logs.cleared`. Every
/// model here parses tolerantly: unknown fields are ignored and a missing field takes
/// its documented "no sample" default, because a host update must not crash an older
/// app.
library;

import 'envelope.dart';

/// Event type names. They are part of RUNTIME_CONTRACT v1; renaming one is a contract
/// change with a version bump, not a refactor.
abstract final class RuntimeEventTypes {
  static const String status = 'runtime.status';
  static const String groups = 'runtime.groups';
  static const String log = 'runtime.log';
  static const String connections = 'runtime.connections';
  static const String modes = 'runtime.modes';
  static const String logsCleared = 'logs.cleared';
}

int _int(Object? value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool _bool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

List<Object?> _list(Object? value) => value is List ? value : const <Object?>[];

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const <String, Object?>{};

/// One `runtime.status` sample. Counters are byte counts; `trafficAvailable == false`
/// means the kernel reported no traffic sample, and the UI must show "—", not 0.
class RuntimeStatusSample {
  const RuntimeStatusSample({
    this.hostEpoch = '',
    this.serviceState = '',
    this.profileId = '',
    this.profileRevision = 0,
    this.memoryBytes = 0,
    this.goroutines = 0,
    this.connectionsIn = 0,
    this.connectionsOut = 0,
    this.trafficAvailable = false,
    this.uplinkBytes = 0,
    this.downlinkBytes = 0,
    this.uplinkTotalBytes = 0,
    this.downlinkTotalBytes = 0,
    this.sampledAt = 0,
  });

  factory RuntimeStatusSample.fromData(Map<String, Object?> data) => RuntimeStatusSample(
    hostEpoch: _string(data['hostEpoch']),
    serviceState: _string(data['serviceState']),
    profileId: _string(data['profileId']),
    profileRevision: _int(data['profileRevision']),
    memoryBytes: _int(data['memoryBytes']),
    goroutines: _int(data['goroutines']),
    connectionsIn: _int(data['connectionsIn']),
    connectionsOut: _int(data['connectionsOut']),
    trafficAvailable: _bool(data['trafficAvailable']),
    uplinkBytes: _int(data['uplinkBytes']),
    downlinkBytes: _int(data['downlinkBytes']),
    uplinkTotalBytes: _int(data['uplinkTotalBytes']),
    downlinkTotalBytes: _int(data['downlinkTotalBytes']),
    sampledAt: _int(data['sampledAt']),
  );

  final String hostEpoch;
  final String serviceState;
  final String profileId;
  final int profileRevision;
  final int memoryBytes;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;
  final bool trafficAvailable;
  final int uplinkBytes;
  final int downlinkBytes;
  final int uplinkTotalBytes;
  final int downlinkTotalBytes;
  final int sampledAt;
}

/// One member of a group. `urlTestDelay == 0` means "not measured or expired".
class RuntimeGroupItem {
  const RuntimeGroupItem({
    required this.tag,
    this.type = '',
    this.urlTestTime = 0,
    this.urlTestDelay = 0,
  });

  factory RuntimeGroupItem.fromData(Map<String, Object?> data) =>
      RuntimeGroupItem(
        tag: _string(data['tag']),
        type: _string(data['type']),
        urlTestTime: _int(data['urlTestTime']),
        urlTestDelay: _int(data['urlTestDelay']),
      );

  final String tag;
  final String type;
  final int urlTestTime;
  final int urlTestDelay;
}

/// A selector/urltest/fallback group as the kernel reports it.
class RuntimeGroup {
  const RuntimeGroup({
    required this.tag,
    this.type = '',
    this.selectable = false,
    this.selected = '',
    this.expanded = false,
    this.items = const <RuntimeGroupItem>[],
  });

  factory RuntimeGroup.fromData(Map<String, Object?> data) => RuntimeGroup(
    tag: _string(data['tag']),
    type: _string(data['type']),
    selectable: _bool(data['selectable']),
    selected: _string(data['selected']),
    expanded: _bool(data['expanded']),
    items: _list(
      data['items'],
    ).map((Object? entry) => RuntimeGroupItem.fromData(_map(entry))).toList(growable: false),
  );

  final String tag;
  final String type;
  final bool selectable;
  final String selected;
  final bool expanded;
  final List<RuntimeGroupItem> items;

  RuntimeGroupItem? member(String tag) {
    for (final RuntimeGroupItem item in items) {
      if (item.tag == tag) return item;
    }
    return null;
  }
}

/// One log line. [level] is sing-box's numeric level; [name] is the contract's string.
class RuntimeLogEntry {
  const RuntimeLogEntry({
    required this.message,
    this.level = 2,
    this.name = 'info',
    this.at = 0,
  });

  factory RuntimeLogEntry.fromData(Map<String, Object?> data) => RuntimeLogEntry(
    message: _string(data['message']),
    level: _int(data['level'], 2),
    name: _string(data['name'], 'info'),
    at: _int(data['at']),
  );

  final String message;
  final int level;
  final String name;
  final int at;
}

/// One connection event from a `runtime.connections` batch.
class RuntimeConnectionEvent {
  const RuntimeConnectionEvent({
    required this.type,
    this.id = '',
    this.network = '',
    this.source = '',
    this.destination = '',
    this.domain = '',
    this.outbound = '',
    this.outboundType = '',
    this.rule = '',
    this.protocol = '',
    this.chain = const <String>[],
    this.createdAt = 0,
    this.closedAt = 0,
    this.uplinkTotalBytes = 0,
    this.downlinkTotalBytes = 0,
    this.uplinkDelta = 0,
    this.downlinkDelta = 0,
  });

  factory RuntimeConnectionEvent.fromData(Map<String, Object?> data) =>
      RuntimeConnectionEvent(
        type: _string(data['type'], 'unknown'),
        id: _string(data['id']),
        network: _string(data['network']),
        source: _string(data['source']),
        destination: _string(data['destination']),
        domain: _string(data['domain']),
        outbound: _string(data['outbound']),
        outboundType: _string(data['outboundType']),
        rule: _string(data['rule']),
        protocol: _string(data['protocol']),
        chain: _list(data['chain']).map(_string).where((String s) => s.isNotEmpty).toList(growable: false),
        createdAt: _int(data['createdAt']),
        closedAt: _int(data['closedAt']),
        uplinkTotalBytes: _int(data['uplinkTotalBytes']),
        downlinkTotalBytes: _int(data['downlinkTotalBytes']),
        uplinkDelta: _int(data['uplinkDelta']),
        downlinkDelta: _int(data['downlinkDelta']),
      );

  final String type;
  final String id;
  final String network;
  final String source;
  final String destination;
  final String domain;
  final String outbound;
  final String outboundType;
  final String rule;
  final String protocol;
  final List<String> chain;
  final int createdAt;
  final int closedAt;
  final int uplinkTotalBytes;
  final int downlinkTotalBytes;
  final int uplinkDelta;
  final int downlinkDelta;

  bool get isClosed => type == 'closed';
}

/// A `runtime.connections` batch. [reset] replaces the table; [instanceId] changes when
/// a reload replaced the Box, and a batch from a stale instance must be dropped.
class RuntimeConnectionBatch {
  const RuntimeConnectionBatch({
    this.reset = false,
    this.resynced = false,
    this.instanceId = '',
    this.sequence = 0,
    this.dropped = 0,
    this.events = const <RuntimeConnectionEvent>[],
  });

  factory RuntimeConnectionBatch.fromData(Map<String, Object?> data) =>
      RuntimeConnectionBatch(
        reset: _bool(data['reset']),
        resynced: _bool(data['resynced']),
        instanceId: _string(data['instanceId']),
        sequence: _int(data['sequence']),
        dropped: _int(data['dropped']),
        events: _list(data['events'])
            .map((Object? entry) => RuntimeConnectionEvent.fromData(_map(entry)))
            .toList(growable: false),
      );

  final bool reset;
  final bool resynced;
  final String instanceId;
  final int sequence;
  final int dropped;
  final List<RuntimeConnectionEvent> events;
}

/// The mode list the running kernel offers. [available] false means the kernel sent no
/// modes (for example, no service), not "the profile disabled them".
class RuntimeModeState {
  const RuntimeModeState({
    this.modes = const <String>[],
    this.current = '',
    this.available = false,
  });

  factory RuntimeModeState.fromData(Map<String, Object?> data) => RuntimeModeState(
    modes: _list(data['modes']).map(_string).where((String s) => s.isNotEmpty).toList(growable: false),
    current: _string(data['current']),
    available: _bool(data['available']),
  );

  final List<String> modes;
  final String current;
  final bool available;
}

/// A parsed runtime event: the kind plus the typed payload for that kind.
class RuntimeEvent {
  const RuntimeEvent._({required this.kind, this.status, this.groups, this.logs, this.connections, this.modes, this.logsCleared = false});

  final String kind;
  final RuntimeStatusSample? status;
  final List<RuntimeGroup>? groups;
  final List<RuntimeLogEntry>? logs;
  final RuntimeConnectionBatch? connections;
  final RuntimeModeState? modes;
  final bool logsCleared;

  /// Returns null for an event type this version does not know: an unknown event must
  /// be ignored, never thrown on.
  static RuntimeEvent? fromCallback(HostCallback callback) {
    switch (callback.type) {
      case RuntimeEventTypes.status:
        return RuntimeEvent._(kind: callback.type, status: RuntimeStatusSample.fromData(callback.data));
      case RuntimeEventTypes.groups:
        return RuntimeEvent._(
          kind: callback.type,
          groups: _list(callback.data['groups'])
              .map((Object? entry) => RuntimeGroup.fromData(_map(entry)))
              .toList(growable: false),
        );
      case RuntimeEventTypes.log:
        return RuntimeEvent._(
          kind: callback.type,
          logs: _list(callback.data['entries'])
              .map((Object? entry) => RuntimeLogEntry.fromData(_map(entry)))
              .toList(growable: false),
        );
      case RuntimeEventTypes.connections:
        return RuntimeEvent._(kind: callback.type, connections: RuntimeConnectionBatch.fromData(callback.data));
      case RuntimeEventTypes.modes:
        return RuntimeEvent._(kind: callback.type, modes: RuntimeModeState.fromData(callback.data));
      case RuntimeEventTypes.logsCleared:
        return RuntimeEvent._(kind: callback.type, logsCleared: true);
      default:
        return null;
    }
  }

  /// The epoch a frame belongs to, when the payload carries one.
  String get hostEpoch {
    final RuntimeStatusSample? statusValue = status;
    if (statusValue != null) return statusValue.hostEpoch;
    return '';
  }
}
