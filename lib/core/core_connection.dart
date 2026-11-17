import 'package:flutter/foundation.dart';

import 'core_bridge.dart';

enum CoreServiceState {
  unavailable,
  stopped,
  starting,
  running,
  stopping,
  failed,
}

/// The single UI-side source of core state. Every transition comes from a
/// bridge answer; when the bridge is absent the state is [unavailable] with a
/// reason and no operation pretends to succeed.
class CoreConnection extends ChangeNotifier {
  CoreConnection({CoreBridge? bridge})
    : facade = CoreFacade(bridge ?? const UnavailableCoreBridge()) {
    _state = facade.availability == CoreAvailability.unavailable
        ? CoreServiceState.unavailable
        : CoreServiceState.stopped;
    _reason = facade.unavailableReason;
  }

  final CoreFacade facade;

  late CoreServiceState _state;
  String? _reason;

  CoreServiceState get state => _state;
  String? get reason => _reason;

  bool get isAvailable => _state != CoreServiceState.unavailable;

  void _set(CoreServiceState next, {String? reason}) {
    if (_state == next && _reason == reason) return;
    _state = next;
    _reason = reason;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!isAvailable) {
      _set(CoreServiceState.unavailable, reason: facade.unavailableReason);
      return;
    }
    try {
      final answer = await facade.serviceStatus();
      final running = answer['running'] == true;
      _set(
        running ? CoreServiceState.running : CoreServiceState.stopped,
        reason: null,
      );
    } on BridgeException catch (error) {
      _set(CoreServiceState.failed, reason: error.message);
    }
  }

  Future<bool> start() async {
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

  /// Returns the kernel's verdict, or throws [BridgeException] when the check
  /// cannot run. Never returns a made-up "valid".
  Future<Map<String, Object?>> checkConfig(String content) =>
      facade.checkConfig(content);

  Future<Map<String, Object?>> applyProfile(String id) =>
      facade.applyProfile(id);
}
