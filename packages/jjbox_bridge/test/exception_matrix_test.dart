import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late FakeHost host;
  late HostBridge bridge;
  late ProfileRepository repository;
  late ProfileSwitchTransaction transaction;

  setUp(() {
    host = FakeHost();
    bridge = HostBridge(transport: host);
    repository = ProfileRepository(bridge: bridge);
    transaction = ProfileSwitchTransaction(
      bridge: bridge,
      repository: repository,
    );
  });

  tearDown(() async {
    await bridge.dispose();
  });

  Future<ProfileWriteResult> write(String body, {String label = 'p'}) =>
      repository.write(label: label, kind: 'local', content: _bytes(body));

  test('E1 file permission denied is a typed error, nothing is written', () async {
    host.failNext(BridgeMethod.filePickConfig, HostErrorCode.permissionDenied);
    await expectLater(
      bridge.pickConfig(),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.permissionDenied,
      )),
    );
    expect(await repository.list(), isEmpty);
  });

  test('E2 a killed UI process leaves host-owned profiles readable', () async {
    final ProfileWriteResult before = await write('{"v":1}');
    await bridge.dispose();
    final HostBridge restarted = HostBridge(transport: host);
    addTearDown(restarted.dispose);
    final ProfileRepository restartedRepository =
        ProfileRepository(bridge: restarted);
    final List<ProfileMeta> profiles = await restartedRepository.list();
    expect(profiles.single.id, before.id);
    expect(utf8.decode((await restartedRepository.read(before.id)).content),
        '{"v":1}');
  });

  test('E3 repeated copy/import does not duplicate the profile', () async {
    final ImportPipeline pipeline = ImportPipeline(
      bridge: bridge,
      repository: repository,
    );
    final ImportPlan plan = await pipeline.prepare(const ImportRequest(
      source: ImportSource.clipboard,
      text: 'vless://11111111-2222-3333-4444-555555555555@example.com:443#demo',
    ));
    final ImportResult first = await pipeline.commit(plan, confirmed: true);
    final ImportResult second = await pipeline.commit(plan, confirmed: true);
    expect(second.profile.id, first.profile.id);
    expect((await repository.list()).length, 1);

    final ClipboardGate gate = ClipboardGate();
    final DateTime now = DateTime.utc(2026, 11, 17, 12);
    expect(
      gate.evaluate(userInitiated: true, foreground: true, text: 'x', now: now),
      ClipboardDecision.accept,
    );
    expect(
      gate.evaluate(
        userInitiated: true,
        foreground: true,
        text: 'x',
        now: now.add(const Duration(seconds: 5)),
      ),
      ClipboardDecision.duplicate,
    );
    expect(
      gate.evaluate(
        userInitiated: true,
        foreground: true,
        text: 'x',
        now: now.add(const Duration(minutes: 2)),
      ),
      ClipboardDecision.accept,
    );
  });

  test('E4 rapid consecutive imports are serialized', () async {
    final ImportPipeline pipeline = ImportPipeline(
      bridge: bridge,
      repository: repository,
    );
    final List<Future<ImportResult>> pending = <Future<ImportResult>>[
      for (int i = 0; i < 3; i++)
        pipeline
            .prepare(ImportRequest(
              source: ImportSource.file,
              text: 'vless://uuid$i@example.com:443#n$i',
            ))
            .then((ImportPlan plan) => pipeline.commit(plan, confirmed: true)),
    ];
    final List<ImportResult> results = await Future.wait(pending);
    expect(results.map((ImportResult r) => r.profile.id).toSet().length, 3);
    final List<String> revisions = (await repository.list())
        .map((ProfileMeta meta) => meta.revision)
        .toList();
    expect(revisions.toSet().length, 3);
  });

  test('E5 background recovery re-applies the known good profile', () async {
    final ProfileWriteResult good = await write('{"v":1}');
    await transaction.switchTo(
      id: good.id,
      revision: good.revision,
      requestId: 'r1',
      mode: 'proxy',
    );
    host.machine.runtimeReport(RuntimeEvidence.stopped);
    host.machine.failPending('service.lost');
    expect(await transaction.recover(), isA<SwitchApplied>());
  });

  test('E6 provider refresh never holds the write lock and flags raced edits',
      () async {
    final ProfileWriteResult profile = await write('{"v":1}');
    host.delayNext(BridgeMethod.providerRefresh, const Duration(milliseconds: 60));
    final ProviderRefreshCoordinator coordinator = ProviderRefreshCoordinator(
      bridge: bridge,
      repository: repository,
    );
    final Future<RefreshOutcome> refresh = coordinator.refresh(<String>['sub']);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repository.idle, isTrue);
    await repository.write(
      id: profile.id,
      label: 'edited during refresh',
      kind: 'local',
      content: _bytes('{"v":2}'),
      expectedRevision: profile.revision,
    );
    final RefreshOutcome outcome = await refresh;
    expect(outcome.supported, isTrue);
    expect(outcome.racedEdits, isTrue);
  });

  test('E7 a core that cannot refresh reports supported:false', () async {
    host.providerRefreshSupported = false;
    final ProviderRefreshCoordinator coordinator = ProviderRefreshCoordinator(
      bridge: bridge,
      repository: repository,
    );
    final RefreshOutcome outcome = await coordinator.refresh(<String>['sub']);
    expect(outcome.supported, isFalse);
    expect(outcome.racedEdits, isFalse);
  });

  test('E8 disk full keeps the previous revision intact', () async {
    final ProfileWriteResult first = await write('{"v":1}');
    host.failNext(BridgeMethod.profileWrite, HostErrorCode.storageWriteFailed);
    await expectLater(
      repository.write(
        id: first.id,
        label: 'edit',
        kind: 'local',
        content: _bytes('{"v":2}'),
        expectedRevision: first.revision,
      ),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.storageWriteFailed,
      )),
    );
    final ProfileContent after = await repository.read(first.id);
    expect(utf8.decode(after.content), '{"v":1}');
  });

  test('E9 a corrupt profile answers storage_corrupt and can be restored',
      () async {
    final ProfileWriteResult first = await write('{"v":1}');
    final ProfileWriteResult second = await repository.write(
      id: first.id,
      label: 'edit',
      kind: 'local',
      content: _bytes('{"v":2}'),
      expectedRevision: first.revision,
    );
    host.corruptProfiles.add(first.id);
    await expectLater(
      repository.read(first.id),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.storageCorrupt,
      )),
    );
    host.corruptProfiles.remove(first.id);
    final ProfileWriteResult restored =
        await repository.restore(first.id, first.revision);
    expect(restored.revision, first.revision);
    expect(second.revision, isNot(first.revision));
  });

  test('E10 a dropped channel surfaces transport_disconnected', () async {
    host.failNext(BridgeMethod.serviceStatus, HostErrorCode.transportDisconnected);
    await expectLater(
      bridge.status(),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.transportDisconnected,
      )),
    );
  });

  test('E11 imports reject unknown kinds before any host call', () async {
    final ImportPipeline pipeline = ImportPipeline(
      bridge: bridge,
      repository: repository,
    );
    await expectLater(
      pipeline.prepare(const ImportRequest(source: ImportSource.qr, text: 'hello')),
      throwsA(isA<ImportException>()),
    );
    expect(host.received, isEmpty);
  });
}
