import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:jiejiebox_flutter/state/runtime_store.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

class RecordingStore extends RuntimeStore {
  final List<String> calls = <String>[];

  @override
  Future<void> select(String group, String tag) async {
    calls.add('select:$group:$tag');
  }

  @override
  Future<void> urlTest(String group) async {
    calls.add('test:$group');
  }

  @override
  Future<void> setMode(String value) async {
    mode = value;
    calls.add('mode:$value');
    notifyListeners();
  }

  @override
  Future<void> closeConnection(String id) async {
    calls.add('close:$id');
  }

  @override
  Future<void> closeAllConnections() async {
    calls.add('closeAll');
  }

  @override
  Future<void> refreshProviders() async {
    calls.add('providers');
  }
}

RecordingStore seededStore() {
  final store = RecordingStore();
  store.applyGroups([
    ProxyGroupView(
      tag: 'Proxy',
      type: 'selector',
      selected: 'Node A',
      nodes: const [
        ProxyNodeView(tag: 'Node A', type: 'vless', delay: 42, selected: true),
        ProxyNodeView(tag: 'Node B', type: 'trojan', delay: -1),
      ],
    ),
    ProxyGroupView(
      tag: 'Auto',
      type: 'urltest',
      selected: 'Node B',
      nodes: const [ProxyNodeView(tag: 'Node B', type: 'trojan', delay: 180)],
    ),
  ], current: 'Proxy');
  store.applyTraffic(
    traffic: const RuntimeTraffic(
      up: 1024,
      down: 2048,
      upTotal: 4096,
      downTotal: 8192,
    ),
    memory: 32 * 1024 * 1024,
    mode: 'rule',
    modes: const ['rule', 'global', 'direct'],
    intranetIp: '192.168.1.20',
    connections: 2,
  );
  store.setConnections(const [
    ConnectionView(
      id: 'c1',
      host: 'example.com',
      destination: 'example.com:443',
      network: 'tcp',
      rule: 'MATCH',
      chain: 'Proxy → Node A',
      upload: 100,
      download: 2000,
    ),
    ConnectionView(id: 'c2', host: 'api.example.org', network: 'udp'),
  ]);
  store.setLogs([
    LogView(timeMillis: 1, level: 'info', message: 'started'),
    LogView(timeMillis: 2, level: 'error', message: 'boom'),
  ]);
  store.setProviders([
    ProviderView(
      name: 'local',
      type: 'inline',
      vehicle: 'inline',
      nodeCount: 2,
    ),
  ]);
  return store;
}

Future<AppState> pumpApp(
  WidgetTester tester,
  Size size,
  RuntimeStore store,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(
    seedProfiles: true,
    initialViewSize: size,
    runtime: store,
  );
  await tester.pumpWidget(
    JiejieBoxApp(state: state, locale: const Locale('en', 'US')),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('proxies show groups and nodes and select calls runtime', (
    tester,
  ) async {
    final store = seededStore();
    final state = await pumpApp(tester, const Size(1280, 880), store);
    state.setPage(PageLabel.proxies);
    await tester.pumpAndSettle();
    expect(find.text('Proxy'), findsWidgets);
    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('42ms'), findsOneWidget);
    await tester.tap(find.text('Node B'));
    expect(store.calls, contains('select:Proxy:Node B'));
  });

  testWidgets('connections show rows and close calls runtime', (tester) async {
    final store = seededStore();
    final state = await pumpApp(tester, const Size(1280, 880), store);
    state.setPage(PageLabel.connections);
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.textContaining('Proxy → Node A'), findsOneWidget);
    await tester.tap(find.byTooltip('Close connection').first);
    expect(store.calls, contains('close:c1'));
  });

  testWidgets('logs filter by level and keep order', (tester) async {
    final store = seededStore();
    final state = await pumpApp(tester, const Size(1280, 880), store);
    state.setPage(PageLabel.logs);
    await tester.pumpAndSettle();
    expect(find.textContaining('started'), findsOneWidget);
    await tester.tap(find.text('error'));
    await tester.pumpAndSettle();
    expect(find.textContaining('started'), findsNothing);
    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('dashboard shows runtime values instead of titles only', (
    tester,
  ) async {
    final store = seededStore();
    final state = await pumpApp(tester, const Size(1280, 880), store);
    state.setPage(PageLabel.dashboard);
    await tester.pumpAndSettle();
    expect(find.text('Node A'), findsWidgets);
    expect(find.text('192.168.1.20'), findsOneWidget);
    expect(find.text('32.0 MB'), findsOneWidget);
    expect(find.textContaining('/s'), findsWidgets);
  });

  test('log buffer is bounded and pause stops appends', () {
    final store = RuntimeStore();
    for (var index = 0; index < 600; index++) {
      store.appendLog(
        LogView(timeMillis: index, level: 'info', message: '$index'),
      );
    }
    expect(store.logs.length, 500);
    store.setPaused(true);
    store.appendLog(const LogView(timeMillis: 1, level: 'info', message: 'x'));
    expect(store.logs.length, 500);
    expect(store.logs.last.message, '599');
  });

  test('imported multi-node config gets one selector and route final', () {
    const nodeA =
        '{"type":"vless","tag":"a","server":"example.com","server_port":443}';
    const nodeB =
        '{"type":"trojan","tag":"b","server":"example.org","server_port":443}';
    final preview = PreviewResult(
      ok: true,
      format: 'links',
      count: 2,
      declared: 2,
      base64: false,
      items: const [
        PreviewItem(tag: 'a', type: 'vless', endpoint: false, content: nodeA),
        PreviewItem(tag: 'b', type: 'trojan', endpoint: false, content: nodeB),
      ],
      skipped: const [],
    );
    final composed = composeImportedConfig(preview)!;
    final config = jsonDecode(composed) as Map<String, Object?>;
    final outbounds = (config['outbounds'] as List)
        .cast<Map<String, Object?>>();
    final selector = outbounds.firstWhere((node) => node['type'] == 'selector');
    expect(selector['outbounds'], ['a', 'b']);
    expect((config['route'] as Map)['final'], 'proxy');
  });
}
