import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

const String _shareLink =
    'vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls#demo';
const String _singbox =
    '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}';
const String _clash =
    'proxies:\n  - name: a\n    type: ss\n    server: example.com\n    port: 8388\nrules:\n  - MATCH,DIRECT\n';
const String _sip008 =
    '{"version":1,"servers":[{"server":"example.com","server_port":443}]}';

void main() {
  late FakeHost host;
  late HostBridge bridge;
  late ImportPipeline pipeline;

  setUp(() {
    host = FakeHost();
    bridge = HostBridge(transport: host);
    pipeline = ImportPipeline(
      bridge: bridge,
      repository: ProfileRepository(bridge: bridge),
    );
  });

  tearDown(() async {
    await bridge.dispose();
  });

  group('classification is routing only', () {
    test('recognises the formats the core validates', () {
      expect(ImportPipeline.classify(_shareLink), ImportKind.shareLink);
      expect(
        ImportPipeline.classify('https://example.com/sub'),
        ImportKind.subscriptionUrl,
      );
      expect(ImportPipeline.classify(_clash), ImportKind.clashYaml);
      expect(ImportPipeline.classify(_sip008), ImportKind.sip008);
      expect(ImportPipeline.classify(_singbox), ImportKind.singboxJson);
      expect(
        ImportPipeline.classify(base64Encode(utf8.encode(_shareLink))),
        ImportKind.base64Bundle,
      );
    });

    test('rejects empty, html and unknown payloads', () {
      expect(ImportPipeline.classify('   '), ImportKind.unknown);
      expect(
        ImportPipeline.classify('<html><body>502</body></html>'),
        ImportKind.unknown,
      );
      expect(ImportPipeline.classify('hello world'), ImportKind.unknown);
      expect(ImportPipeline.classify('{"foo":1}'), ImportKind.unknown);
    });
  });

  test('sha256 matches the FIPS vectors', () {
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(<int>[]),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  test('a share link is previewed, then written only when confirmed', () async {
    final ImportPlan plan = await pipeline.prepare(
      const ImportRequest(source: ImportSource.qr, text: _shareLink),
    );
    expect(plan.kind, ImportKind.shareLink);
    expect(plan.preview!.count, 2);

    await expectLater(
      pipeline.commit(plan, confirmed: false),
      throwsA(
        isA<ImportException>().having(
          (ImportException error) => error.code,
          'code',
          HostErrorCode.invalidArgument,
        ),
      ),
    );
    expect(await pipeline.repository.list(), isEmpty);

    final ImportResult result = await pipeline.commit(plan, confirmed: true);
    expect(result.profile.revision, isNotEmpty);
    expect(result.deduplicated, isFalse);
  });

  test('importing the same bytes twice returns the same profile', () async {
    final ImportPlan plan = await pipeline.prepare(
      ImportRequest(source: ImportSource.file, bytes: _bytes(_shareLink)),
    );
    final ImportResult first = await pipeline.commit(plan, confirmed: true);
    final ImportResult second = await pipeline.commit(plan, confirmed: true);
    expect(second.deduplicated, isTrue);
    expect(second.profile.id, first.profile.id);
    expect((await pipeline.repository.list()).length, 1);
  });

  test(
    'a full sing-box document is validated by the core before writing',
    () async {
      final ImportPlan plan = await pipeline.prepare(
        const ImportRequest(source: ImportSource.clipboard, text: _singbox),
      );
      expect(plan.kind, ImportKind.singboxJson);
      expect(plan.check!.ok, isTrue);

      host.failNext(BridgeMethod.configCheck, HostErrorCode.coreRejectedConfig);
      await expectLater(
        pipeline.prepare(
          ImportRequest(source: ImportSource.file, bytes: _bytes(_singbox)),
        ),
        throwsA(
          isA<ImportException>().having(
            (ImportException error) => error.code,
            'code',
            HostErrorCode.coreRejectedConfig,
          ),
        ),
      );
    },
  );

  test(
    'the core rejection message reaches the caller as a typed error',
    () async {
      host.failNext(BridgeMethod.configCheck, HostErrorCode.coreRejectedConfig);
      await expectLater(
        pipeline.prepare(
          ImportRequest(source: ImportSource.file, bytes: _bytes(_singbox)),
        ),
        throwsA(isA<ImportException>()),
      );
    },
  );

  group('QR payloads', () {
    test('empty input is rejected', () async {
      await expectLater(
        pipeline.prepare(
          const ImportRequest(source: ImportSource.qr, text: ''),
        ),
        throwsA(
          isA<ImportException>().having(
            (ImportException error) => error.code,
            'code',
            HostErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('script and data schemes are rejected', () async {
      for (final String payload in <String>[
        'javascript:alert(1)',
        'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==',
        'file:///etc/passwd',
      ]) {
        await expectLater(
          pipeline.prepare(
            ImportRequest(source: ImportSource.qr, text: payload),
          ),
          throwsA(isA<ImportException>()),
          reason: payload,
        );
      }
    });

    test('control characters and oversized payloads are rejected', () async {
      await expectLater(
        pipeline.prepare(
          const ImportRequest(
            source: ImportSource.qr,
            text: 'vless://a\u0000b',
          ),
        ),
        throwsA(isA<ImportException>()),
      );
      await expectLater(
        pipeline.prepare(
          ImportRequest(source: ImportSource.qr, text: 'vless://${'a' * 5000}'),
        ),
        throwsA(isA<ImportException>()),
      );
    });
  });

  test('oversized input is rejected before touching the host', () async {
    final ImportPipeline small = ImportPipeline(
      bridge: bridge,
      repository: ProfileRepository(bridge: bridge),
      maxBytes: 4,
    );
    await expectLater(
      small.prepare(
        const ImportRequest(source: ImportSource.file, text: _shareLink),
      ),
      throwsA(isA<ImportException>()),
    );
    expect(
      host.received.where(
        (HostRequest r) => r.method == BridgeMethod.configPreview,
      ),
      isEmpty,
    );
  });

  test('unknown payloads never reach the host', () async {
    await expectLater(
      pipeline.prepare(
        const ImportRequest(source: ImportSource.file, text: 'not a config'),
      ),
      throwsA(isA<ImportException>()),
    );
    expect(host.received, isEmpty);
  });
}
