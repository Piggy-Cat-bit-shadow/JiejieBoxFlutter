import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_bridge.dart';
import 'host_core_bridge.dart';

enum CoreServiceState {
  unavailable,
  stopped,
  starting,
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
  StreamSubscription<({jb.HostCallback callback, bool gap})>? _events;

  CoreServiceState get state => _state;
  String? get reason => _reason;
  int get revision => _revision;
  jb.RuntimeStatus? get runtimeStatus => _status;

  bool get isAvailable => _state != CoreServiceState.unavailable;

  bool get hasRealHost => host != null;

  void _listen() {
    final bridge = host;
    if (bridge == null) return;
    _events = bridge.events.listen((event) {
      final type = event.callback.type;
      if (type.startsWith('service.') || event.gap) {
        unawaited(refresh());
      }
    });
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
    'stopping' => CoreServiceState.stopping,
    'stopped' => CoreServiceState.stopped,
    'failed' => CoreServiceState.failed,
    _ => CoreServiceState.failed,
  };

  void _applyStatus(jb.RuntimeStatus status) {
    _status = status;
    _revision = status.revision;
    _set(_mapState(status.state), reason: status.lastError?.message);
  }

  Future<void> refresh() async {
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
    String mode = 'vpn',
  }) async {
    final bridge = host;
    if (bridge != null) {
      if (profileId == null || profileRevision == null) {
        _set(CoreServiceState.failed, reason: 'no profile selected');
        return false;
      }
      _set(CoreServiceState.starting);
      try {
        final ack = await bridge.start(
          revision: _revision,
          mode: mode,
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
        final ack = await bridge.stop(revision: _revision);
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
  }) => _requireHost().applyProfile(
    id: id,
    revision: revision,
    requestId: '${DateTime.now().microsecondsSinceEpoch}',
  );

  Future<jb.ProviderRefreshResult> refreshProviders(List<String> tags) =>
      _requireHost().refreshProviders(tags);

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
