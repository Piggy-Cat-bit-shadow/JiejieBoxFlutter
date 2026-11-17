import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/core/core_connection.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';
import 'package:jjbox_bridge/testing.dart';

class _Harness {
  _Harness({bool providerRefresh = true}) : fake = FakeHost() {
    fake.providerRefreshSupported = providerRefresh;
    fake.profiles['p1'] = Uint8List.fromList(utf8.encode(kSingboxJson));
    fake.revisions['p1'] = 'rev-1';
    fake.profiles['p2'] = Uint8List.fromList(utf8.encode(kSingboxJson));
    fake.revisions['p2'] = 'rev-2';
    host = HostBridge(transport: fake);
    connection = CoreConnection(host: host);
    state = AppState(
      seedProfiles: false,
      initialViewSize: const Size(1280, 880),
      coreConnection: connection,
    );
  }

  final FakeHost fake;
  late final HostBridge host;
  late final CoreConnection connection;
  late final AppState state;

  Future<void> boot() async {
    await state.bootstrap();
    await connection.refresh();
  }
}

Future<void> _pump(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1280, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    JiejieBoxApp(state: state, locale: const Locale('en', 'US')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('host profiles are rendered from profile.list', (tester) async {
    final harness = _Harness();
    await harness.boot();
    await _pump(tester, harness.state);
    expect(harness.state.profiles.map((p) => p.id), contains('p1'));
    expect(find.text('p1'), findsOneWidget);
    expect(
      harness.fake.received.map((r) => r.method),
      contains('profile.list'),
    );
  });

  test('config.check reports valid and typed failure', () async {
    final harness = _Harness();
    await harness.boot();
    final good = await harness.connection.checkConfig(kSingboxJson);
    expect(good.ok, isTrue);

    harness.fake.failNext('config.check', HostErrorCode.coreRejectedConfig);
    await expectLater(
      harness.connection.checkConfig(kSingboxJson),
      throwsA(
        isA<HostError>().having(
          (e) => e.code,
          'code',
          HostErrorCode.coreRejectedConfig,
        ),
      ),
    );
  });

  test('import preview + validated write + list refresh', () async {
    final harness = _Harness();
    await harness.boot();
    final id = await harness.state.importConfig(
      label: 'imported',
      content: kSingboxJson,
    );
    expect(id, isNotNull);
    expect(
      harness.fake.received.map((r) => r.method),
      contains('config.preview'),
    );
    final write = harness.fake.received.lastWhere(
      (request) => request.method == 'profile.write',
    );
    expect(write.args['validate'], isTrue);
    expect(harness.fake.profiles.containsKey(id), isTrue);
    // FakeHost answers profile.list with the id as label; the point is that
    // the write reached the host and the list was reloaded from it.
    expect(harness.state.profiles.length, 3);
    expect(harness.state.profiles.map((p) => p.id), contains(id));
  });

  test('service.start/stop use the host state machine', () async {
    final harness = _Harness();
    await harness.boot();
    harness.state.selectProfile('p1');
    final started = await harness.state.startService();
    expect(started, isTrue, reason: harness.state.lastActionError);
    expect(
      harness.fake.received.map((r) => r.method),
      contains('service.start'),
    );
    harness.fake.reportRuntime(RuntimeEvidence.running, revision: 0);
    await harness.connection.refresh();
    expect(harness.connection.state, CoreServiceState.running);

    final stopped = await harness.state.stopService();
    expect(stopped, isTrue, reason: harness.state.lastActionError);
    expect(
      harness.fake.received.map((r) => r.method),
      contains('service.stop'),
    );
  });

  test('apply failure keeps the previous profile and its revision', () async {
    final harness = _Harness();
    await harness.boot();
    harness.state.selectProfile('p1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    harness.fake.failNext('profile.apply', HostErrorCode.revisionMismatch);
    harness.state.selectProfile('p2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(harness.state.selectedProfileId, 'p1');
    expect(harness.state.lastActionError, contains('mismatch'));
    expect(harness.state.currentProfile?.revision, 'rev-1');
  });

  test('write failure leaves the host list untouched and reports it', () async {
    final harness = _Harness();
    await harness.boot();
    harness.fake.failNext('profile.write', HostErrorCode.storageWriteFailed);
    final id = await harness.state.importConfig(
      label: 'imported',
      content: kSingboxJson,
    );
    expect(id, isNull);
    expect(harness.state.lastActionError, isNotNull);
    expect(harness.state.profiles.length, 2);
  });

  test('provider.refresh supported:false is reported, not faked', () async {
    final harness = _Harness(providerRefresh: false);
    await harness.boot();
    await harness.state.refreshProviders();
    expect(harness.state.providerRefreshStatus, contains('not supported'));
  });
}
