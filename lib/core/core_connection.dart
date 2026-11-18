import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_bridge.dart';
import 'host_core_bridge.dart';

enum CoreServiceState {
  unavailable,
  stopped,
  starting,
  awaitingPermission,
  running,
  stopping,
  failed,
}

/// The single UI-side source of core state.
///
/// With a typed host it follows `service.status`/events and drives the real
/// profile/config API. Without one it is [CoreServiceState.unavailable] with a
/// reason, and every operation fails instead of pretending.
class CoreConnection extends ChangeNotifier {
  CoreConnection({CoreBridge? bridge, jb.HostBridge? host})
    : host = host,
      facade = CoreFacade(
        bridge ??
            (host == null
                ? const UnavailableCoreBridge()
                : HostCoreBridge(host)),
      ) {
    _state = facade.availability == CoreAvailability.unavailable
        ? CoreServiceState.unavailable
        : CoreServiceState.stopped;
    _reason = facade.unavailableReason;
    _listen();
  }

  final CoreFacade facade;
  final jb.HostBridge? host;

  late CoreServiceState _state;
  String? _reason;
  int _revision = 0;
  jb.RuntimeStatus? _status;
  jb.HostCapabilities? _capabilities;
  StreamSubscription<({jb.HostCallback callback, bool gap})>? _events;
  Timer? _poll;
  bool _disposed = false;

  CoreServiceState get state => _state;
  String? get reason => _reason;
  int get revision => _revision;
  jb.RuntimeStatus? get runtimeStatus => _status;
  jb.HostCapabilities? get capabilities => _capabilities;

  bool get isAvailable => _state != CoreServiceState.unavailable;

  bool get hasRealHost => host != null;

  void _listen() {
    final bridge = host;
    if (bridge == null) return;
    unawaited(refreshCapabilities());
    _events = bridge.events.listen((event) {
      final type = event.callback.type;
      if (type.startsWith('service.') || event.gap) {
        unawaited(refresh());
      }
    });
    // The Windows plugin's callback pump is still being finished, so a periodic
    // status poll keeps the shell truthful even when an event frame is missed.
    // Widget tests drive refresh() themselves and must not be left with a timer.
    if (Platform.environment['FLUTTER_TEST'] != 'true') {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!_disposed) unawaited(refresh());
      });
    }
  }

  void _set(CoreServiceState next, {String? reason}) {
    if (_state == next && _reason == reason) return;
    _state = next;
    _reason = reason;
    notifyListeners();
  }

  CoreServiceState _mapState(String wire) => switch (wire) {
    'running' => CoreServiceState.running,
    'starting' => CoreServiceState.starting,
    'awaitingPermission' => CoreServiceState.awaitingPermission,
    'awaitingpermission' => CoreServiceState.awaitingPermission,
    'stopping' => CoreServiceState.stopping,
    'stopped' => CoreServiceState.stopped,
    'idle' => CoreServiceState.stopped,
    'failed' => CoreServiceState.failed,
    _ => CoreServiceState.failed,
  };

  void _applyStatus(jb.RuntimeStatus status) {
    _status = status;
    _revision = status.revision;
    _set(_mapState(status.state), reason: status.lastError?.message);
  }

  Future<void> refreshCapabilities() async {
    final bridge = host;
    if (bridge == null) return;
    try {
      _capabilities = await bridge.capabilities();
      notifyListeners();
    } on Object {
      // The availability probe remains the authority; a transient capability
      // query failure must not turn a reachable host into unavailable.
    }
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final bridge = host;
    if (bridge != null) {
      try {
        _applyStatus(await bridge.status());
      } on jb.HostError catch (error) {
        _set(CoreServiceState.failed, reason: error.message);
      }
      return;
    }
    if (!isAvailable) {
      _set(CoreServiceState.unavailable, reason: facade.unavailableReason);
      return;
    }
    try {
      final answer = await facade.serviceStatus();
      _set(
        answer['running'] == true
            ? CoreServiceState.running
            : CoreServiceState.stopped,
      );
    } on BridgeException catch (error) {
      _set(CoreServiceState.failed, reason: error.message);
    }
  }

  Future<bool> start({
    String? profileId,
    String? profileRevision,
    String? mode,
  }) async {
    final bridge = host;
    if (bridge != null) {
      if (profileId == null || profileRevision == null) {
        _set(CoreServiceState.failed, reason: 'no profile selected');
        return false;
      }
      final String resolvedMode = mode ?? await _modeForHost(bridge);
      _set(CoreServiceState.starting);
      try {
        final ack = await bridge.start(
          revision: _revision + 1,
          mode: resolvedMode,
          profileId: profileId,
          profileRevision: profileRevision,
        );
        await refresh();
        // An accepted intent is not a running core: the state comes from
        // service.status/events. Return the ack, not a guessed "running".
        return ack.accepted;
      } on jb.HostError catch (error) {
        _set(CoreServiceState.failed, reason: error.message);
        return false;
      }
    }
    if (!isAvailable) {
      _set(CoreServiceState.unavailable, reason: facade.unavailableReason);
      return false;
    }
    _set(CoreServiceState.starting);
    try {
      await facade.startService();
      await refresh();
      return true;
    } on BridgeException catch (error) {
      _set(CoreServiceState.failed, reason: error.message);
      return false;
    }
  }

  Future<bool> stop() async {
    final bridge = host;
    if (bridge != null) {
      _set(CoreServiceState.stopping);
      try {
        final ack = await bridge.stop(revision: _revision + 1);
        await refresh();
        return ack.accepted;
      } on jb.HostError catch (error) {
        _set(CoreServiceState.failed, reason: error.message);
        return false;
      }
    }
    if (!isAvailable) {
      _set(CoreServiceState.unavailable, reason: facade.unavailableReason);
      return false;
    }
    _set(CoreServiceState.stopping);
    try {
      await facade.stopService();
      await refresh();
      return true;
    } on BridgeException catch (error) {
      _set(CoreServiceState.failed, reason: error.message);
      return false;
    }
  }

  jb.HostBridge _requireHost() {
    final bridge = host;
    if (bridge == null) {
      throw const BridgeException(
        'host_unavailable',
        'Platform bridge is not connected',
      );
    }
    return bridge;
  }

  Future<jb.ConfigCheckResult> checkConfig(String content) async =>
      _requireHost().checkConfig(Uint8List.fromList(utf8.encode(content)));

  Future<jb.PreviewResult> preview(String content) async =>
      _requireHost().preview(Uint8List.fromList(utf8.encode(content)));

  Future<List<jb.ProfileMeta>> listProfiles() => _requireHost().listProfiles();

  Future<jb.ProfileContent> readProfile(String id) =>
      _requireHost().readProfile(id);

  Future<jb.PickedFile?> pickConfig() => _requireHost().pickConfig();

  Future<String> _modeForHost(jb.HostBridge bridge) async {
    try {
      final jb.HostCapabilities caps = await bridge.capabilities();
      if (caps.serviceModes.contains('vpn')) return 'vpn';
      if (caps.serviceModes.contains('proxy')) return 'proxy';
    } on Object {
      // Fall through to the platform default.
    }
    return _defaultServiceMode();
  }

  Future<jb.ProfileWriteResult> writeProfile({
    String? id,
    required String label,
    required String content,
    required String kind,
    String? expectedRevision,
    bool validate = true,
  }) => _requireHost().writeProfile(
    id: id,
    label: label,
    kind: kind,
    content: Uint8List.fromList(utf8.encode(content)),
    expectedRevision: expectedRevision,
    validate: validate,
  );

  Future<void> deleteProfile(String id, {String? expectedRevision}) =>
      _requireHost().deleteProfile(id, expectedRevision: expectedRevision);

  Future<jb.ApplyReport> applyProfile({
    required String id,
    required String revision,
  }) async {
    final report = await _requireHost().applyProfile(
      id: id,
      revision: revision,
      requestId: '${DateTime.now().microsecondsSinceEpoch}',
      mode: await _modeForHost(_requireHost()),
    );
    // The host advances its own intent revision on apply; refresh so a later
    // stop uses a revision newer than the one the apply consumed.
    await refresh();
    return report;
  }

  Future<jb.ProviderRefreshResult> refreshProviders(List<String> tags) =>
      _requireHost().refreshProviders(tags);

  Future<bool> applySystemProxy({
    required bool enabled,
    int port = 0,
    List<String> bypass = const <String>[],
  }) => _requireHost().applySystemProxy(
    enabled: enabled,
    port: port,
    bypass: bypass,
  );

  Future<jb.SystemProxyStatus> systemProxyStatus({int port = 0}) =>
      _requireHost().systemProxyStatus(port: port);

  Future<bool> setAutoLaunch(bool enabled) =>
      _requireHost().setAutoLaunch(enabled);

  Future<bool> autoLaunchStatus() => _requireHost().autoLaunchStatus();

  Future<void> updateTray({
    required bool running,
    required String mode,
    required int proxyPort,
    List<Map<String, Object?>> groups = const <Map<String, Object?>>[],
  }) => _requireHost().updateTray(
    running: running,
    mode: mode,
    proxyPort: proxyPort,
    groups: groups,
  );

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _events?.cancel();
    super.dispose();
  }
}

String _defaultServiceMode() {
  // Windows and macOS expose a proxy core. Android has a VpnService/TUN path
  // when the AAR is linked; iOS is always a Network Extension TUN.
  if (Platform.isAndroid || Platform.isIOS) return 'vpn';
  return 'proxy';
}
