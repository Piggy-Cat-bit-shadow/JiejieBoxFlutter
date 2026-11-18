import 'dart:collection';

import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

/// The single source of runtime truth for the UI (RUNTIME_CONTRACT v1).
///
/// It owns the bounded collections and the epoch/sequence rules, so a page never keeps a
/// second copy of "what the core is doing". Everything here is derived from kernel
/// frames; nothing is invented to fill a card.
class RuntimeSource {
  RuntimeSource({this.maxLogs = 1000, this.maxConnections = 2000});

  /// Hard caps from the contract (§11). They bound memory even if the host misbehaves.
  final int maxLogs;
  final int maxConnections;

  jb.RuntimeStatusSample? _status;
  List<jb.RuntimeGroup> _groups = const <jb.RuntimeGroup>[];
  jb.RuntimeModeState _modes = const jb.RuntimeModeState();
  final ListQueue<jb.RuntimeLogEntry> _logs = ListQueue<jb.RuntimeLogEntry>();
  final LinkedHashMap<String, jb.RuntimeConnectionEvent> _connections =
      LinkedHashMap<String, jb.RuntimeConnectionEvent>();

  String _epoch = '';
  int _lastSeq = 0;
  int _gapCount = 0;
  String _connectionInstance = '';

  jb.RuntimeStatusSample? get status => _status;
  List<jb.RuntimeGroup> get groups => _groups;
  jb.RuntimeModeState get modes => _modes;
  List<jb.RuntimeLogEntry> get logs => _logs.toList(growable: false);
  List<jb.RuntimeConnectionEvent> get connections =>
      _connections.values.toList(growable: false);
  String get hostEpoch => _epoch;
  int get lastSeq => _lastSeq;

  /// How many times the host's sequence skipped. A non-zero value means the UI should
  /// treat the runtime picture as possibly incomplete (the host drops the oldest frames
  /// when the queue is full).
  int get gapCount => _gapCount;

  /// Applies one callback. Returns true when visible state changed.
  ///
  /// Order of checks matters:
  /// 1. a frame from another host process (epoch change) resets everything first, so a
  ///    stale frame can never merge into the new process's state;
  /// 2. a sequence that does not advance is a duplicate and is dropped;
  /// 3. unknown event types are ignored, not thrown on.
  bool apply(jb.HostCallback callback) {
    final jb.RuntimeEvent? event = jb.RuntimeEvent.fromCallback(callback);
    if (event == null) {
      return false;
    }
    final bool resetByEpoch = _applyEpoch(callback);
    if (callback.seq != 0) {
      if (callback.seq <= _lastSeq) {
        return resetByEpoch;
      }
      if (callback.seq != _lastSeq + 1 && _lastSeq != 0) {
        _gapCount++;
      }
      _lastSeq = callback.seq;
    }

    if (event.status != null) {
      _status = event.status;
      return true;
    }
    if (event.groups != null) {
      _groups = event.groups!;
      return true;
    }
    if (event.logs != null) {
      for (final jb.RuntimeLogEntry entry in event.logs!) {
        _logs.addLast(entry);
      }
      while (_logs.length > maxLogs) {
        _logs.removeFirst();
      }
      return true;
    }
    if (event.logsCleared) {
      _logs.clear();
      return true;
    }
    if (event.modes != null) {
      _modes = event.modes!;
      return true;
    }
    final jb.RuntimeConnectionBatch? batch = event.connections;
    if (batch != null) {
      return _applyConnections(batch) || resetByEpoch;
    }
    return resetByEpoch;
  }

  /// Epoch handling: a different host process voids every cached frame.
  ///
  /// The reset happens BEFORE the frame is applied, and the frame that revealed the new
  /// epoch is then applied normally (it belongs to the new process). Reading the epoch
  /// from the raw payload, rather than only from the status model, means a groups or log
  /// frame arriving first after a restart also triggers the reset.
  bool _applyEpoch(jb.HostCallback callback) {
    final Object? rawEpoch = callback.data['hostEpoch'];
    final String frameEpoch = rawEpoch is String ? rawEpoch : '';
    if (frameEpoch.isEmpty || frameEpoch == _epoch) {
      return false;
    }
    final bool hadEpoch = _epoch.isNotEmpty;
    _epoch = frameEpoch;
    if (!hadEpoch) {
      return false;
    }
    reset();
    _epoch = frameEpoch;
    return true;
  }

  bool _applyConnections(jb.RuntimeConnectionBatch batch) {
    if (batch.instanceId.isNotEmpty && batch.instanceId != _connectionInstance) {
      // A reload replaced the Box: the old instance's rows must not survive.
      _connections.clear();
      _connectionInstance = batch.instanceId;
    }
    if (batch.reset) {
      _connections.clear();
    }
    for (final jb.RuntimeConnectionEvent event in batch.events) {
      if (event.isClosed) {
        _connections.remove(event.id);
        continue;
      }
      if (event.id.isEmpty) {
        continue;
      }
      _connections[event.id] = _mergeConnection(_connections[event.id], event);
    }
    while (_connections.length > maxConnections) {
      _connections.remove(_connections.keys.first);
    }
    return true;
  }

  /// An update event carries deltas and no immutable fields; merge instead of replace so
  /// a delta cannot blank the destination the UI is showing.
  jb.RuntimeConnectionEvent _mergeConnection(
    jb.RuntimeConnectionEvent? previous,
    jb.RuntimeConnectionEvent event,
  ) {
    if (previous == null) {
      return event;
    }
    return jb.RuntimeConnectionEvent(
      type: event.type,
      id: event.id,
      network: event.network.isEmpty ? previous.network : event.network,
      source: event.source.isEmpty ? previous.source : event.source,
      destination: event.destination.isEmpty ? previous.destination : event.destination,
      domain: event.domain.isEmpty ? previous.domain : event.domain,
      outbound: event.outbound.isEmpty ? previous.outbound : event.outbound,
      outboundType: event.outboundType.isEmpty ? previous.outboundType : event.outboundType,
      rule: event.rule.isEmpty ? previous.rule : event.rule,
      protocol: event.protocol.isEmpty ? previous.protocol : event.protocol,
      chain: event.chain.isEmpty ? previous.chain : event.chain,
      createdAt: event.createdAt == 0 ? previous.createdAt : event.createdAt,
      closedAt: event.closedAt,
      uplinkTotalBytes: previous.uplinkTotalBytes + event.uplinkDelta,
      downlinkTotalBytes: previous.downlinkTotalBytes + event.downlinkDelta,
      uplinkDelta: event.uplinkDelta,
      downlinkDelta: event.downlinkDelta,
    );
  }

  /// Clears the runtime picture but keeps the epoch: a stop/reconnect is not a new host.
  void reset() {
    _status = null;
    _groups = const <jb.RuntimeGroup>[];
    _modes = const jb.RuntimeModeState();
    _logs.clear();
    _connections.clear();
    _connectionInstance = '';
    _lastSeq = 0;
  }

  /// Full reset including the host identity, used when the app loses the host entirely.
  void dispose() {
    reset();
    _epoch = '';
    _gapCount = 0;
  }
}
