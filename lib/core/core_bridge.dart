/// The Dart side of the C platform bridge contract
/// (`OUTPUT/CONTRACTS/platform_bridge.contract.json`).
///
/// Method names and the error envelope are the contract's, not invented here.
/// Until C's `lib/bridge` lands, [UnavailableCoreBridge] answers every call
/// with [BridgeException] so no screen can render a simulated success.
library;

class BridgeException implements Exception {
  const BridgeException(this.code, this.message, {this.detail});

  final String code;
  final String message;
  final Map<String, Object?>? detail;

  @override
  String toString() => 'BridgeException($code): $message';
}

enum CoreAvailability { unavailable, available }

/// The 25 contract methods are invoked through one envelope; typed facade
/// methods below cover the subset the P3 UI uses.
abstract interface class CoreBridge {
  CoreAvailability get availability;

  String? get unavailableReason;

  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]);
}

class UnavailableCoreBridge implements CoreBridge {
  const UnavailableCoreBridge([
    this.unavailableReason = 'Platform bridge is not connected',
  ]);

  @override
  final String? unavailableReason;

  @override
  CoreAvailability get availability => CoreAvailability.unavailable;

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    throw BridgeException(
      'host_unavailable',
      unavailableReason ?? 'Platform bridge is not connected',
      detail: {'method': method},
    );
  }
}

/// Typed view of the methods P3 needs; every value comes from the bridge.
class CoreFacade {
  const CoreFacade(this.bridge);

  final CoreBridge bridge;

  CoreAvailability get availability => bridge.availability;

  String? get unavailableReason => bridge.unavailableReason;

  Future<Map<String, Object?>> serviceStatus() =>
      bridge.invoke('service.status');

  Future<Map<String, Object?>> startService() => bridge.invoke('service.start');

  Future<Map<String, Object?>> stopService() => bridge.invoke('service.stop');

  Future<Map<String, Object?>> checkConfig(String content) =>
      bridge.invoke('config.check', {'content': content});

  Future<Map<String, Object?>> previewConfig(String content) =>
      bridge.invoke('config.preview', {'content': content});

  Future<Map<String, Object?>> applyProfile(String id) =>
      bridge.invoke('profile.apply', {'id': id});

  Future<Map<String, Object?>> profiles() => bridge.invoke('profile.list');

  Future<Map<String, Object?>> refreshProviders(List<String> tags) =>
      bridge.invoke('provider.refresh', {'tags': tags});

  Future<Map<String, Object?>> capabilities() =>
      bridge.invoke('core.capabilities');
}

/// Test-only fake: answers the envelope but is never used by the app root.
class ScriptedCoreBridge implements CoreBridge {
  ScriptedCoreBridge(this.answers, {this.failure});

  final Map<String, Map<String, Object?>> answers;
  final BridgeException? failure;

  @override
  CoreAvailability get availability => CoreAvailability.available;

  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final error = failure;
    if (error != null) {
      throw error;
    }
    final answer = answers[method];
    if (answer == null) {
      throw BridgeException('method_not_found', method);
    }
    return answer;
  }
}
