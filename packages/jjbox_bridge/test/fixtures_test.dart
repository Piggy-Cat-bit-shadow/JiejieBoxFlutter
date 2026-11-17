import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

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

  test('fixtures never carry credentials', () {
    for (final ImportFixture fixture in importFixtures) {
      expect(fixture.text.toLowerCase(), isNot(contains('password')), reason: fixture.name);
      expect(fixture.text, isNot(contains('BEGIN PRIVATE KEY')), reason: fixture.name);
    }
  });

  test('every fixture that names a kind classifies to it', () {
    for (final ImportFixture fixture in importFixtures) {
      if (fixture.expectedKind == null) {
        continue;
      }
      expect(
        ImportPipeline.classify(fixture.text),
        fixture.expectedKind,
        reason: fixture.name,
      );
    }
  });

  test('every error fixture is rejected before writing', () async {
    for (final ImportFixture fixture in importFixtures) {
      if (!fixture.expectError) {
        continue;
      }
      await expectLater(
        pipeline.prepare(ImportRequest(
          source: fixture.source,
          text: fixture.text,
        )),
        throwsA(isA<ImportException>()),
        reason: fixture.name,
      );
    }
    expect(await pipeline.repository.list(), isEmpty);
  });

  test('every valid fixture prepares through the fake core', () async {
    for (final ImportFixture fixture in importFixtures) {
      if (fixture.expectError) {
        continue;
      }
      final ImportPlan plan = await pipeline.prepare(ImportRequest(
        source: fixture.source,
        text: fixture.text,
      ));
      expect(plan.kind, fixture.expectedKind, reason: fixture.name);
      expect(plan.sha256.length, 64, reason: fixture.name);
      expect(plan.bytes.length, greaterThan(0), reason: fixture.name);
    }
  });

  test('an endpoint-bearing document is routed to the core, not rewritten', () async {
    final ImportPlan plan = await pipeline.prepare(
      const ImportRequest(source: ImportSource.file, text: kSingboxWithEndpoint),
    );
    expect(plan.check!.ok, isTrue);
    expect(utf8.decode(plan.bytes), kSingboxWithEndpoint);
  });
}
