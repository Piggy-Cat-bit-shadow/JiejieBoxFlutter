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

  setUp(() {
    host = FakeHost();
    bridge = HostBridge(transport: host);
    repository = ProfileRepository(bridge: bridge);
  });

  tearDown(() async {
    await bridge.dispose();
  });

  Future<ProfileWriteResult> write(String body, {String? label}) {
    return repository.write(
      label: label ?? body,
      kind: 'local',
      content: _bytes(body),
    );
  }

  test('mutations are serialized and every revision is observable', () async {
    final List<Future<ProfileWriteResult>> pending = <Future<ProfileWriteResult>>[
      write('{"a":1}'),
      write('{"a":2}'),
      write('{"a":3}'),
    ];
    expect(repository.queued, 3);
    final List<ProfileWriteResult> results =
        await Future.wait(pending);
    expect(repository.queued, 0);
    expect(results.map((ProfileWriteResult r) => r.id).toSet().length, 3);

    final List<ProfileMeta> profiles = await repository.list();
    expect(profiles.length, 3);
    for (final ProfileMeta meta in profiles) {
      final ProfileContent content = await repository.read(meta.id);
      expect(sha256Hex(content.content).substring(0, 16), meta.revision);
    }
  });

  test('expectedRevision mismatch never overwrites', () async {
    final ProfileWriteResult first = await write('{"v":1}');
    await expectLater(
      repository.write(
        id: first.id,
        label: 'edit',
        kind: 'local',
        content: _bytes('{"v":2}'),
        expectedRevision: 'stale',
      ),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.revisionMismatch,
      )),
    );
    final ProfileContent after = await repository.read(first.id);
    expect(utf8.decode(after.content), '{"v":1}');
  });

  test('restore swaps the retained revision back in', () async {
    final ProfileWriteResult first = await write('{"v":1}');
    final ProfileWriteResult second = await repository.write(
      id: first.id,
      label: 'edit',
      kind: 'local',
      content: _bytes('{"v":2}'),
      expectedRevision: first.revision,
    );
    final ProfileWriteResult restored =
        await repository.restore(first.id, first.revision);
    expect(restored.revision, first.revision);
    final ProfileContent after = await repository.read(first.id);
    expect(utf8.decode(after.content), '{"v":1}');
    expect(second.revision, isNot(first.revision));
  });

  test('restoring an unknown revision is a typed mismatch', () async {
    final ProfileWriteResult first = await write('{"v":1}');
    await expectLater(
      repository.restore(first.id, 'deadbeef'),
      throwsA(isA<HostError>().having(
        (HostError error) => error.code,
        'code',
        HostErrorCode.revisionMismatch,
      )),
    );
  });

  test('a failed apply keeps the previous profile and last-good', () async {
    final ProfileWriteResult good = await write('{"v":1}');
    final ProfileSwitchTransaction transaction = ProfileSwitchTransaction(
      bridge: bridge,
      repository: repository,
    );
    final SwitchOutcome applied = await transaction.switchTo(
      id: good.id,
      revision: good.revision,
      requestId: 'r1',
      mode: 'proxy',
    );
    expect(applied, isA<SwitchApplied>());
    expect(transaction.lastGood.toString(), '${good.id}@${good.revision}');

    host.failNext(BridgeMethod.profileApply, HostErrorCode.coreStartFailed);
    final SwitchOutcome rejected = await transaction.switchTo(
      id: good.id,
      revision: good.revision,
      requestId: 'r2',
      mode: 'proxy',
    );
    expect(rejected, isA<SwitchRejected>());
    expect(transaction.lastGood.toString(), '${good.id}@${good.revision}');
  });

  test('recover re-applies the known good profile once', () async {
    final ProfileWriteResult good = await write('{"v":1}');
    final ProfileSwitchTransaction transaction = ProfileSwitchTransaction(
      bridge: bridge,
      repository: repository,
    );
    await transaction.switchTo(
      id: good.id,
      revision: good.revision,
      requestId: 'r1',
      mode: 'proxy',
    );
    host.reportRuntime(RuntimeEvidence.stopped);
    host.machine.failPending('service.lost');
    final SwitchOutcome recovered = await transaction.recover();
    expect(recovered, isA<SwitchApplied>());
    host.reportRuntime(RuntimeEvidence.running);
    final SwitchOutcome again = await transaction.recover();
    expect(again, isA<SwitchNoop>());
  });

  test('recover without a known good profile is a noop', () async {
    final ProfileSwitchTransaction transaction = ProfileSwitchTransaction(
      bridge: bridge,
      repository: repository,
    );
    expect(await transaction.recover(), isA<SwitchNoop>());
  });
}
