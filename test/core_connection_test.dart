import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/core/core_bridge.dart';
import 'package:jiejiebox_flutter/core/core_connection.dart';

void main() {
  test(
    'no bridge means unavailable, with a reason, and no fake running',
    () async {
      final connection = CoreConnection();
      expect(connection.state, CoreServiceState.unavailable);
      expect(connection.reason, 'Platform bridge is not connected');
      expect(await connection.start(), isFalse);
      expect(connection.state, CoreServiceState.unavailable);
      expect(
        () => connection.checkConfig('{}'),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.code,
            'code',
            'host_unavailable',
          ),
        ),
      );
    },
  );

  test('bridge status decides running/stopped', () async {
    final bridge = ScriptedCoreBridge({
      'service.status': {'running': true},
    });
    final connection = CoreConnection(bridge: bridge);
    expect(connection.state, CoreServiceState.stopped);
    await connection.refresh();
    expect(connection.state, CoreServiceState.running);
  });

  test('bridge failure maps to failed with reason, not success', () async {
    final connection = CoreConnection(
      bridge: ScriptedCoreBridge(
        const {},
        failure: const BridgeException('core_start_failed', 'boom'),
      ),
    );
    expect(await connection.start(), isFalse);
    expect(connection.state, CoreServiceState.failed);
    expect(connection.reason, 'boom');
  });
}
