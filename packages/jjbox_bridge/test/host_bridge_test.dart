import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

void main() {
  late FakeHost host;
  late HostBridge bridge;

  setUp(() {
    host = FakeHost(tun: true);
    bridge = HostBridge(transport: host);
  });

  tearDown(() async {
    await bridge.dispose();
  });

  test('capabilities are typed and branchable', () async {
    final HostCapabilities capabilities = await bridge.capabilities();
    expect(capabilities.tun, isTrue);
    expect(capabilities.serviceModes, contains('vpn'));
    expect(capabilities.qrImageDecode, isTrue);
  });

  test('core capabilities carry the build facts B requires', () async {
    final CoreCapabilities core = await bridge.coreCapabilities();
    expect(core.apiVersion, 4);
    expect(core.buildQuic, isTrue);
    expect(core.canRunProtocol('hysteria2'), isTrue);
    expect(core.canRunProtocol('vless'), isTrue);
    expect(core.canRunProtocol('wireguard'), isFalse);
  });

  test('a start ack is not running', () async {
    final StartAck ack = await bridge.start(
      revision: 1,
      mode: 'proxy',
      profileId: 'p1',
      profileRevision: 'sha-1',
    );
    expect(ack.accepted, isTrue);
    final RuntimeStatus status = await bridge.status();
    expect(status.isRunning, isFalse);
    expect(status.state, isNot('running'));
  });

  test('runtime evidence drives the state and the event stream', () async {
    final Future<String> running = bridge.events
        .where(
          (event) =>
              event.callback.type == 'service.state' &&
              event.callback.data['state'] == 'running',
        )
        .map((event) => event.callback.type)
        .first;
    await bridge.start(
      revision: 1,
      mode: 'proxy',
      profileId: 'p1',
      profileRevision: 'sha-1',
    );
    expect((await bridge.status()).state, 'starting');
    host.reportRuntime(RuntimeEvidence.running);
    expect(await running, 'service.state');
    final RuntimeStatus status = await bridge.status();
    expect(status.isRunning, isTrue);
  });

  test('permission denial fails the start instead of hanging', () async {
    final FakeHost gated = FakeHost(
      tun: true,
      requestPermission: true,
      permission: PermissionEvidence.unrequested,
    );
    final HostBridge gatedBridge = HostBridge(transport: gated);
    addTearDown(gatedBridge.dispose);
    await gatedBridge.start(
      revision: 1,
      mode: 'vpn',
      profileId: 'p1',
      profileRevision: 'sha-1',
    );
    expect((await gatedBridge.status()).state, 'awaitingPermission');
    gated.reportPermission(PermissionEvidence.denied);
    expect((await gatedBridge.status()).state, 'failed');
  });

  test('typed errors survive the round trip', () async {
    host.failNext(BridgeMethod.configCheck, HostErrorCode.coreRejectedConfig);
    await expectLater(
      bridge.checkConfig(Uint8List.fromList(utf8.encode('{}'))),
      throwsA(
        isA<HostError>().having(
          (HostError error) => error.code,
          'code',
          HostErrorCode.coreRejectedConfig,
        ),
      ),
    );
  });

  test('unknown methods answer unsupported_platform', () async {
    await expectLater(
      bridge.invoke('nope.nothing'),
      throwsA(
        isA<HostError>().having(
          (HostError error) => error.code,
          'code',
          HostErrorCode.unsupportedPlatform,
        ),
      ),
    );
  });

  test('a slow host becomes a timeout error', () async {
    final FakeHost slow = FakeHost();
    final HostBridge shortBridge = HostBridge(
      transport: slow,
      timeout: const Duration(milliseconds: 30),
    );
    addTearDown(shortBridge.dispose);
    slow.delayNext(
      BridgeMethod.serviceStatus,
      const Duration(milliseconds: 200),
    );
    await expectLater(
      shortBridge.status(),
      throwsA(
        isA<HostError>().having(
          (HostError error) => error.code,
          'code',
          HostErrorCode.timeout,
        ),
      ),
    );
  });

  test('profile write/read/list/delete keep a content revision', () async {
    final ProfileWriteResult written = await bridge.writeProfile(
      label: 'demo',
      kind: 'local',
      content: Uint8List.fromList(utf8.encode('{"log":{"level":"info"}}')),
    );
    expect(written.revision, isNotEmpty);
    final List<ProfileMeta> list = await bridge.listProfiles();
    expect(list.single.id, written.id);
    final ProfileContent read = await bridge.readProfile(written.id);
    expect(utf8.decode(read.content), contains('"level":"info"'));
    await bridge.deleteProfile(written.id);
    expect(await bridge.listProfiles(), isEmpty);
  });

  test('a stale expectedRevision is rejected', () async {
    final ProfileWriteResult first = await bridge.writeProfile(
      label: 'demo',
      kind: 'local',
      content: Uint8List.fromList(utf8.encode('{}')),
    );
    await expectLater(
      bridge.writeProfile(
        id: first.id,
        label: 'demo',
        kind: 'local',
        content: Uint8List.fromList(utf8.encode('{}')),
        expectedRevision: 'stale',
      ),
      throwsA(
        isA<HostError>().having(
          (HostError error) => error.code,
          'code',
          HostErrorCode.revisionMismatch,
        ),
      ),
    );
  });

  test(
    'preview never carries item content, only endpoints and skips',
    () async {
      final PreviewResult preview = await bridge.preview(
        Uint8List.fromList(utf8.encode('vless://a\nvless://b\nssr://c')),
      );
      expect(preview.ok, isTrue);
      expect(preview.count, 2);
      expect(preview.declared, 3);
      expect(preview.skipped.single.reason, contains('ssr'));
      expect(preview.items.every((PreviewItem item) => !item.endpoint), isTrue);
    },
  );

  test('refresh reports supported separately from success', () async {
    final ProviderRefreshResult result = await bridge.refreshProviders(<String>[
      'sub',
    ]);
    expect(result.supported, isTrue);
    expect(result.refreshed, <String>['sub']);
  });

  test('callback gaps are detected for resync', () async {
    final List<bool> gaps = <bool>[];
    final StreamSubscription<({HostCallback callback, bool gap})> sub = bridge
        .events
        .listen((event) => gaps.add(event.gap));
    addTearDown(sub.cancel);
    host.emitRaw('core.log', <String, Object?>{'level': 'info'});
    host.emitRaw('core.log', <String, Object?>{'level': 'warn'});
    await Future<void>.delayed(Duration.zero);
    expect(gaps, <bool>[false, false]);
    expect(host.received, isEmpty);
  });
}
