import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

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
class HostRuntimeStore extends RuntimeStore {
  HostRuntimeStore(this.bridge) {
    _events = bridge.events.listen((event) {
      final callback = event.callback;
      switch (callback.type) {
        case 'runtime.log':
          final line = _parseLog(callback.data);
          if (line != null) appendLog(line);
        case 'runtime.connections':
          final list = _parseConnections(callback.data['items']);
          if (list != null) setConnections(list);
        case 'runtime.state':
          final data = callback.data;
          applyTraffic(
            traffic: _parseTraffic(data),
            memory: (data['memory'] as num?)?.toInt(),
            mode: data['mode'] as String?,
            modes: (data['modes'] as List<Object?>?)
                ?.whereType<String>()
                .toList(growable: false),
            intranetIp: data['intranetIp'] as String?,
            connections: (data['connections'] as num?)?.toInt(),
          );
      }
    });
  }

  final jb.HostBridge bridge;
  late final StreamSubscription<({jb.HostCallback callback, bool gap})> _events;
  Timer? _timer;

  static const _status = 'runtime.status';
  static const _groups = 'runtime.groups';
  static const _select = 'runtime.select';
  static const _urlTest = 'runtime.urlTest';
  static const _setMode = 'runtime.setMode';
  static const _connections = 'runtime.connections';
  static const _close = 'runtime.closeConnection';
  static const _closeAll = 'runtime.closeConnections';
  static const _logs = 'runtime.logs';
  static const _providers = 'runtime.providers';
  static const _refreshProviders = 'runtime.refreshProviders';

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
    await Future.wait([
      refreshStatus(),
      refreshGroups(),
      refreshConnections(),
      refreshLogs(),
      refreshProviders(),
    ]);
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
    final data = await _call(_status);
    if (data == null) return;
    applyTraffic(
      traffic: _parseTraffic(data),
      memory: (data['memory'] as num?)?.toInt(),
      mode: data['mode'] as String?,
      modes: (data['modes'] as List<Object?>?)?.whereType<String>().toList(
        growable: false,
      ),
      intranetIp: data['intranetIp'] as String?,
      connections: (data['connections'] as num?)?.toInt(),
    );
  }

  @override
  Future<void> refreshGroups() async {
    final data = await _call(_groups);
    if (data == null) return;
    final list = <ProxyGroupView>[];
    for (final entry in (data['groups'] as List<Object?>?) ?? const []) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final nodes = <ProxyNodeView>[];
      for (final raw in (map['outbounds'] as List<Object?>?) ?? const []) {
        if (raw is! Map) continue;
        final node = raw.cast<String, Object?>();
        nodes.add(
          ProxyNodeView(
            tag: node['tag'] as String? ?? '',
            type: node['type'] as String? ?? '',
            delay: (node['delay'] as num?)?.toInt(),
            selected: node['selected'] == true,
          ),
        );
      }
      list.add(
        ProxyGroupView(
          tag: map['tag'] as String? ?? '',
          type: map['type'] as String? ?? '',
          nodes: nodes,
          selected: map['selected'] as String?,
        ),
      );
    }
    applyGroups(list, current: data['current'] as String?);
  }

  @override
  Future<void> select(String group, String tag) async {
    final data = await _call(_select, {'group': group, 'tag': tag});
    if (data != null) await refreshGroups();
  }

  @override
  Future<void> urlTest(String group) async {
    final data = await _call(_urlTest, {'group': group});
    if (data != null) await refreshGroups();
  }

  @override
  Future<void> setMode(String value) async {
    final data = await _call(_setMode, {'mode': value});
    if (data != null) {
      mode = value;
      notifyListeners();
    }
  }

  Future<void> refreshConnections() async {
    final data = await _call(_connections);
    if (data == null) return;
    setConnections(_parseConnections(data['items']) ?? const []);
  }

  @override
  Future<void> closeConnection(String id) async {
    await _call(_close, {'id': id});
    await refreshConnections();
  }

  @override
  Future<void> closeAllConnections() async {
    await _call(_closeAll);
    await refreshConnections();
  }

  Future<void> refreshLogs() async {
    final data = await _call(_logs);
    if (data == null) return;
    final list = <LogView>[];
    for (final raw in (data['items'] as List<Object?>?) ?? const []) {
      if (raw is Map) {
        final parsed = _parseLog(raw.cast<String, Object?>());
        if (parsed != null) list.add(parsed);
      }
    }
    setLogs(list);
  }

  @override
  Future<void> clearKernelLogs() async {
    await _call('runtime.clearLogs');
    clearLogs();
  }

  @override
  Future<void> refreshProviders() async {
    final data = await _call(_providers);
    if (data == null) return;
    final list = <ProviderView>[];
    for (final raw in (data['providers'] as List<Object?>?) ?? const []) {
      if (raw is! Map) continue;
      final map = raw.cast<String, Object?>();
      list.add(
        ProviderView(
          name: map['name'] as String? ?? '',
          type: map['type'] as String? ?? '',
          vehicle: map['vehicle'] as String? ?? '',
          nodeCount: (map['nodes'] as num?)?.toInt() ?? 0,
          updatedAtMillis: (map['updatedAt'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    setProviders(list);
  }

  Future<void> refreshProvider(String name) async {
    if (providers.isEmpty) await refreshProviders();
    final data = await _call(_refreshProviders, {
      'tags': [name],
    });
    if (data == null) return;
    await refreshProviders();
    if (data['supported'] == false) {
      providerError = 'Provider refresh is not supported by this host';
      notifyListeners();
    }
  }

  RuntimeTraffic _parseTraffic(Map<String, Object?> data) => RuntimeTraffic(
    up: (data['up'] as num?)?.toInt() ?? traffic.up,
    down: (data['down'] as num?)?.toInt() ?? traffic.down,
    upTotal: (data['upTotal'] as num?)?.toInt() ?? traffic.upTotal,
    downTotal: (data['downTotal'] as num?)?.toInt() ?? traffic.downTotal,
  );

  LogView? _parseLog(Map<String, Object?> data) {
    final message = data['message'] as String?;
    if (message == null) return null;
    return LogView(
      timeMillis: (data['time'] as num?)?.toInt() ?? 0,
      level: (data['level'] as String? ?? 'info').toLowerCase(),
      message: message,
    );
  }

  List<ConnectionView>? _parseConnections(Object? raw) {
    if (raw is! List) return null;
    final list = <ConnectionView>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      list.add(
        ConnectionView(
          id: map['id'] as String? ?? '',
          host: map['host'] as String? ?? map['destination'] as String? ?? '',
          destination: map['destination'] as String? ?? '',
          network: map['network'] as String? ?? '',
          rule: map['rule'] as String? ?? '',
          chain: (map['chain'] as List<Object?>?)?.join(' → ') ?? '',
          upload: (map['upload'] as num?)?.toInt() ?? 0,
          download: (map['download'] as num?)?.toInt() ?? 0,
          startMillis: (map['start'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return list;
  }

  @override
  void dispose() {
    stopPolling();
    _events.cancel();
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
