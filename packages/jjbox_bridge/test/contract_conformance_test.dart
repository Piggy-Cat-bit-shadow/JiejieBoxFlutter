import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

/// Guards the machine-readable contract revision from the Dart side: a method or
/// error code added to the JSON must arrive here in the same change.
void main() {
  test('the method table is the contract revision', () {
    expect(BridgeMethod.all.length, 25);
    expect(BridgeMethod.all.toSet().length, BridgeMethod.all.length);
    final RegExp area = RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$');
    for (final String method in BridgeMethod.all) {
      expect(area.hasMatch(method), isTrue, reason: method);
    }
    expect(BridgeMethod.profileRestore, isIn(BridgeMethod.all));
  });

  test('the error vocabulary is the contract revision', () {
    expect(HostErrorCode.values.length, 20);
    final RegExp snake = RegExp(r'^[a-z][a-z0-9_]*$');
    for (final HostErrorCode code in HostErrorCode.values) {
      expect(snake.hasMatch(code.wireName), isTrue, reason: code.wireName);
    }
    expect(
      HostErrorCode.values.map((HostErrorCode c) => c.wireName).toSet().length,
      HostErrorCode.values.length,
    );
  });

  test('the fake host answers every contract method', () async {
    final FakeHost host = FakeHost();
    final HostBridge bridge = HostBridge(transport: host);
    addTearDown(bridge.dispose);
    for (final String method in BridgeMethod.all) {
      try {
        await bridge.invoke(method);
      } on HostError catch (error) {
        expect(
          error.code,
          isNot(HostErrorCode.unsupportedPlatform),
          reason: '$method is not handled by the fake host',
        );
      }
    }
  });
}
