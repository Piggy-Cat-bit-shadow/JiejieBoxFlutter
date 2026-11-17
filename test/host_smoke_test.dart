import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

const String _validJson =
    '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],'
    '"route":{"final":"direct"}}';
const String _invalidJson = '{"outbounds":[}';

/// Runs only when a real host is listening:
/// `$env:JJBOX_SMOKE_ENDPOINT='127.0.0.1:47831'; flutter test test/host_smoke_test.dart`
void main() {
  final String? endpoint = Platform.environment['JJBOX_SMOKE_ENDPOINT'];
  test('real core_host answers the contract', () async {
    final parts = endpoint!.split(':');
    final transport = await SocketHostTransport.connect(
      parts[0],
      int.parse(parts[1]),
    );
    final bridge = HostBridge(transport: transport);
    final capabilities = await bridge.capabilities();
    expect(capabilities.serviceModes, isNotEmpty);

    // The host links no libbox in this environment (C-04): both a valid and an
    // invalid config must fail with the host's own `core_unavailable`, which is
    // the honest answer rather than a fabricated "valid".
    for (final content in <String>[_validJson, _invalidJson]) {
      try {
        await bridge.checkConfig(Uint8List.fromList(utf8.encode(content)));
        fail('checkConfig must not succeed without libbox');
      } on HostError catch (error) {
        expect(error.code, HostErrorCode.coreUnavailable);
      }
    }

    final written = await bridge.writeProfile(
      label: 'smoke',
      kind: 'singbox-json',
      content: Uint8List.fromList(utf8.encode(_validJson)),
      validate: false,
    );
    expect(written.id, isNotEmpty);
    final list = await bridge.listProfiles();
    expect(list.map((p) => p.id), contains(written.id));
    final read = await bridge.readProfile(written.id);
    expect(utf8.decode(read.content), _validJson);

    final status = await bridge.status();
    expect(status.state, isNotEmpty);
    Map<String, Object?>? refresh;
    try {
      refresh = await bridge.invoke(BridgeMethod.providerRefresh, {
        'tags': <String>[],
        'timeoutMillis': 1000,
      });
    } on HostError catch (error) {
      refresh = {'error': error.code.wireName};
    }
    // ignore: avoid_print
    print(
      'REAL_HOST modes=${capabilities.serviceModes} '
      'check=core_unavailable(valid+invalid) '
      'write=${written.id} profiles=${list.length} '
      'state=${status.state} provider=$refresh',
    );
    await transport.dispose();
  }, skip: endpoint == null ? 'JJBOX_SMOKE_ENDPOINT not set' : false);
}
