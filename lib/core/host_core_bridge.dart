import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_bridge.dart';

/// Production adapter: turns the typed `HostBridge` into the app's
/// [CoreBridge]. Wire method names are the contract's; host errors keep their
/// contract code so the UI can render the right copy.
class HostCoreBridge implements CoreBridge {
  HostCoreBridge(this.host);

  final jb.HostBridge host;

  @override
  CoreAvailability get availability => CoreAvailability.available;

  @override
  String? get unavailableReason => null;

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await host.invoke(method, args);
    } on jb.HostError catch (error) {
      throw BridgeException(
        error.code.wireName,
        error.message,
        detail: {'retryable': error.retryable},
      );
    }
  }
}
