import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import '../core/runtime_source.dart';

/// Runtime view-models and the single store the UI reads.
///
/// B owns the wire contract (`CONTRACTS/RUNTIME_CONTRACT.md`). Until that
/// lands, every field is parsed from the `runtime.*` envelope in one place
/// here; the methods used are listed in `OUTPUT_CLOSEOUT/A/Q8/INTERFACE_REQUESTS.md`.
/// No screen invents values: a missing method becomes an error state.
class ProxyNodeView {
  const ProxyNodeView({
    required this.tag,
    required this.type,
    this.delay,
    this.selected = false,
    this.testing = false,
  });

  final String tag;
  final String type;
  final int? delay;
  final bool selected;
  final bool testing;

  ProxyNodeView copyWith({int? delay, bool? selected, bool? testing}) =>
      ProxyNodeView(
        tag: tag,
        type: type,
        delay: delay ?? this.delay,
        selected: selected ?? this.selected,
        testing: testing ?? this.testing,
      );

  String get latencyLabel {
    final value = delay;
    if (testing) return '...';
    if (value == null) return '--';
    if (value < 0) return 'timeout';
    return '${value}ms';
  }

  bool get timedOut => delay != null && delay! < 0;
}

class ProxyGroupView {
  const ProxyGroupView({
    required this.tag,
    required this.type,
    required this.nodes,
    this.selected,
  });

  final String tag;
  final String type;
  final List<ProxyNodeView> nodes;
  final String? selected;

  ProxyGroupView copyWith({List<ProxyNodeView>? nodes, String? selected}) =>
      ProxyGroupView(
        tag: tag,
        type: type,
        nodes: nodes ?? this.nodes,
        selected: selected ?? this.selected,
      );
}

class ProviderView {
  const ProviderView({
    required this.name,
    required this.type,
    this.vehicle = '',
    this.nodeCount = 0,
    this.updatedAtMillis = 0,
    this.refreshing = false,
    this.error,
  });

  final String name;
  final String type;
  final String vehicle;
  final int nodeCount;
  final int updatedAtMillis;
  final bool refreshing;
  final String? error;
}

class ConnectionView {
  const ConnectionView({
    required this.id,
    required this.host,
    this.destination = '',
    this.network = '',
    this.rule = '',
    this.chain = '',
    this.upload = 0,
    this.download = 0,
    this.startMillis = 0,
  });

  final String id;
  final String host;
  final String destination;
  final String network;
  final String rule;
  final String chain;
  final int upload;
  final int download;
  final int startMillis;
}

class LogView {
  const LogView({
    required this.timeMillis,
    required this.level,
    required this.message,
  });

  final int timeMillis;
  final String level;
  final String message;
}

class RuntimeTraffic {
  const RuntimeTraffic({
    this.up = 0,
    this.down = 0,
    this.upTotal = 0,
    this.downTotal = 0,
  });

  final int up;
  final int down;
  final int upTotal;
  final int downTotal;
}

class RuntimeStore extends ChangeNotifier {
  RuntimeStore();

  ProxyGroupView? _group;
  List<ProxyGroupView> groups = <ProxyGroupView>[];
  final List<ProxyNodeView> _visibleNodes = <ProxyNodeView>[];
  String _query = '';
  String? _groupQuery;

  List<ConnectionView> connections = <ConnectionView>[];
  final List<LogView> logs = <LogView>[];
  List<ProviderView> providers = <ProviderView>[];
  RuntimeTraffic traffic = const RuntimeTraffic();
  List<String> modes = <String>[];
  String? mode;
  String? currentOutbound;
  String? intranetIp;
  int memoryBytes = 0;
  int connectionCount = 0;
  int startedAtMillis = 0;
  bool loading = false;
  bool paused = false;
  String? error;
  String logLevel = 'all';
  String? logError;
  String? providerError;

  static const _logLimit = 500;

  ProxyGroupView? get group => _group;
  String get query => _query;
  String get groupQuery => _groupQuery ?? '';

  List<ProxyNodeView> get visibleNodes {
    final lower = _query.toLowerCase();
    if (lower.isEmpty) return List<ProxyNodeView>.unmodifiable(_visibleNodes);
    return _visibleNodes
        .where(
          (node) =>
              node.tag.toLowerCase().contains(lower) ||
              node.type.toLowerCase().contains(lower),
        )
        .toList(growable: false);
  }

  int get activeCount => connections.length;

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void selectGroup(String tag) {
    _groupQuery = tag;
    final match = groups.where((group) => group.tag == tag).firstOrNull;
    if (match != null) {
      _group = match;
      _visibleNodes
        ..clear()
        ..addAll(match.nodes);
    }
    notifyListeners();
  }

  void applyGroups(List<ProxyGroupView> next, {String? current}) {
    groups = next;
    _group =
        next.where((group) => group.tag == _groupQuery).firstOrNull ??
        next.firstOrNull;
    _visibleNodes
      ..clear()
      ..addAll(_group?.nodes ?? const <ProxyNodeView>[]);
    currentOutbound = current;
    notifyListeners();
  }

  void applyTraffic({
    RuntimeTraffic? traffic,
    int? memory,
    String? mode,
    List<String>? modes,
    String? intranetIp,
    int? connections,
  }) {
    this.traffic = traffic ?? this.traffic;
    memoryBytes = memory ?? memoryBytes;
    this.mode = mode ?? this.mode;
    this.modes = modes ?? this.modes;
    this.intranetIp = intranetIp ?? this.intranetIp;
    connectionCount = connections ?? connectionCount;
    notifyListeners();
  }

  void setConnections(List<ConnectionView> next) {
    connections = next;
    connectionCount = next.length;
    notifyListeners();
  }

  void appendLog(LogView line) {
    if (paused) return;
    logs.add(line);
    if (logs.length > _logLimit) {
      logs.removeRange(0, logs.length - _logLimit);
    }
    notifyListeners();
  }

  void setLogs(List<LogView> next) {
    logs
      ..clear()
      ..addAll(next.take(_logLimit));
    notifyListeners();
  }

  void setPaused(bool value) {
    paused = value;
    notifyListeners();
  }

  void setLogLevel(String value) {
    logLevel = value;
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  void setProviders(List<ProviderView> next) {
    providers = next;
    notifyListeners();
  }

  void setError(String? value) {
    error = value;
    loading = false;
    notifyListeners();
  }

  void setLoading(bool value) {
    loading = value;
    notifyListeners();
  }

  void setConnectionError(String? value) {
    providerError = value;
    notifyListeners();
  }

  Future<void> refreshGroups() async {}
  Future<void> select(String group, String tag) async {}
  Future<void> urlTest(String group) async {}
  Future<void> setMode(String mode) async {}
  Future<void> closeConnection(String id) async {}
  Future<void> closeAllConnections() async {}
  Future<void> refreshProviders() async {}
  Future<void> clearKernelLogs() async {}
  void startPolling() {}
  void stopPolling() {}
}

/// The production store; every value comes from the host's runtime envelope.
///
/// B owns the wire contract (`RuntimeSource`). This adapter is the only place where
/// the UI's view-models meet the typed runtime frames: unknown event types stay
/// ignored, a missing sample keeps the previous value, and every RPC name is the
/// host's name (group.select / mode.set / connections.close / ...), not the old
/// A-side `runtime.*` polling names.
class HostRuntimeStore extends RuntimeStore {
  HostRuntimeStore(this.bridge) {
    _events = bridge.events.listen((event) {
      if (_source.apply(event.callback)) {
        _syncFromSource();
      }
    });
  }

  final jb.HostBridge bridge;
  final RuntimeSource _source = RuntimeSource();
  late final StreamSubscription<({jb.HostCallback callback, bool gap})> _events;
  Timer? _timer;
  int _lastLogCount = 0;

  @override
  void startPolling() {
    _timer?.cancel();
    unawaited(refreshAll());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (paused) return;
      unawaited(refreshStatus());
    });
  }

  @override
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refreshAll() async {
    setLoading(true);
    // Runtime data is pushed by the host; this only seeds the current snapshot.
    _syncFromSource();
    setLoading(false);
  }

  Future<Map<String, Object?>?> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await bridge.invoke(method, args);
    } on jb.HostError catch (error) {
      setError(error.message);
      return null;
    }
  }

  Future<void> refreshStatus() async {
    // No polling RPC: runtime.status is an event. Keep the timer as a cheap
    // liveness tick so a silent host surfaces as a stale UI, not fake numbers.
  }

  @override
  Future<void> refreshGroups() async {}

  @override
  Future<void> select(String group, String tag) async {
    final data = await _call('group.select', {
      'group': group,
      'outbound': tag,
      'requestId': '',
      'expectedRevision': 0,
    });
    if (data != null) await refreshGroups();
  }

  @override
  Future<void> urlTest(String group) async {
    final data = await _call('group.urlTest', {'group': group});
    if (data != null) await refreshGroups();
  }

  @override
  Future<void> setMode(String value) async {
    final data = await _call('mode.set', {'mode': value});
    if (data != null) {
      mode = value;
      notifyListeners();
    }
  }

  Future<void> refreshConnections() async {}

  @override
  Future<void> closeConnection(String id) async {
    await _call('connections.close', {'id': id});
  }

  @override
  Future<void> closeAllConnections() async {
    await _call('connections.closeAll');
  }

  Future<void> refreshLogs() async {}

  @override
  Future<void> clearKernelLogs() async {
    final data = await _call('logs.clear');
    if (data != null) clearLogs();
  }

  Future<void> refreshProviders() async {
    // The kernel does not export a provider catalogue in this API version.
    setProviders(const <ProviderView>[]);
    providerError = 'This core does not expose a provider catalogue';
  }

  Future<void> refreshProvider(String name) async {
    final data = await _call('provider.refresh', {
      'tags': [name],
      'timeoutMillis': 5000,
    });
    if (data == null) return;
    if (data['supported'] == false) {
      providerError = 'Provider refresh is not supported by this host';
      notifyListeners();
    } else {
      providerError = null;
      notifyListeners();
    }
  }

  void _syncFromSource() {
    final status = _source.status;
    if (status != null) {
      applyTraffic(
        traffic: RuntimeTraffic(
          up: status.uplinkBytes,
          down: status.downlinkBytes,
          upTotal: status.uplinkTotalBytes,
          downTotal: status.downlinkTotalBytes,
        ),
        memory: status.memoryBytes,
        connections: status.connectionsIn + status.connectionsOut,
      );
    }

    final modeState = _source.modes;
    if (modeState.available) {
      applyTraffic(mode: modeState.current, modes: modeState.modes);
    }

    final runtimeGroups = _source.groups;
    if (runtimeGroups.isNotEmpty) {
      final groups = runtimeGroups
          .map((group) {
            final nodes = group.items
                .map((item) {
                  final delay = item.urlTestDelay;
                  return ProxyNodeView(
                    tag: item.tag,
                    type: item.type,
                    delay: delay == 0 ? null : delay,
                    selected: group.selected == item.tag,
                  );
                })
                .toList(growable: false);
            return ProxyGroupView(
              tag: group.tag,
              type: group.type,
              nodes: nodes,
              selected: group.selected.isEmpty ? null : group.selected,
            );
          })
          .toList(growable: false);
      final selected = runtimeGroups
          .where((group) => group.selected.isNotEmpty)
          .map((group) => group.selected)
          .firstOrNull;
      applyGroups(groups, current: selected);
    }

    final runtimeLogs = _source.logs;
    if (runtimeLogs.length != _lastLogCount) {
      _lastLogCount = runtimeLogs.length;
      setLogs(
        runtimeLogs
            .map(
              (entry) => LogView(
                timeMillis: entry.at,
                level: entry.name,
                message: entry.message,
              ),
            )
            .toList(growable: false),
      );
    }

    final runtimeConnections = _source.connections;
    setConnections(
      runtimeConnections
          .map(
            (entry) => ConnectionView(
              id: entry.id,
              host: entry.domain.isNotEmpty ? entry.domain : entry.destination,
              destination: entry.destination,
              network: entry.network,
              rule: entry.rule,
              chain: entry.chain.join(' > '),
              upload: entry.uplinkTotalBytes,
              download: entry.downlinkTotalBytes,
              startMillis: entry.createdAt,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  void dispose() {
    stopPolling();
    _events.cancel();
    _source.dispose();
    super.dispose();
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String formatRate(int bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

String formatRelative(int millis) {
  if (millis == 0) return '';
  final diff = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(millis),
  );
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

/// Re-exported so pages can debug-log a snapshot without importing dart:convert
/// in every file.
String encodeSnapshot(Map<String, Object?> value) => jsonEncode(value);
