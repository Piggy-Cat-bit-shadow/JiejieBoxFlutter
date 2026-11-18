import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:jiejiebox_flutter/state/runtime_store.dart';
import 'package:prism_ui/prism_ui.dart';

RuntimeStore _store() {
  final store = RuntimeStore();
  store.applyGroups([
    ProxyGroupView(
      tag: 'Proxy',
      type: 'selector',
      selected: 'Node A',
      nodes: const [
        ProxyNodeView(tag: 'Node A', type: 'vless', delay: 42, selected: true),
        ProxyNodeView(tag: 'Node B', type: 'trojan', delay: 180),
        ProxyNodeView(tag: 'Node C', type: 'hysteria2', delay: -1),
      ],
    ),
  ], current: 'Proxy');
  store.setConnections(const [
    ConnectionView(
      id: 'c1',
      host: 'example.com',
      network: 'tcp',
      rule: 'MATCH',
      chain: 'Proxy → Node A',
      upload: 1024,
      download: 4096,
    ),
  ]);
  store.setLogs([
    LogView(timeMillis: 0, level: 'info', message: 'service started'),
    LogView(timeMillis: 0, level: 'error', message: 'example failure'),
  ]);
  return store;
}

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = await file.readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<AppState> _pump(WidgetTester tester, Size size, PageLabel page) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(
    seedProfiles: true,
    initialViewSize: size,
    runtime: _store(),
  );
  state.setPage(page);
  await tester.pumpWidget(
    JiejieBoxApp(state: state, locale: const Locale('en', 'US')),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  setUpAll(() async {
    await _loadFont('Roboto', r'C:\Windows\Fonts\segoeui.ttf');
    await _loadFont('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf');
  });

  for (final (size, page, name) in <(Size, PageLabel, String)>[
    (const Size(1280, 880), PageLabel.proxies, 'proxies_1280x880'),
    (const Size(375, 667), PageLabel.proxies, 'proxies_375x667'),
    (const Size(1280, 880), PageLabel.connections, 'connections_1280x880'),
    (const Size(375, 667), PageLabel.connections, 'connections_375x667'),
    (const Size(1280, 880), PageLabel.logs, 'logs_1280x880'),
    (const Size(375, 667), PageLabel.logs, 'logs_375x667'),
  ]) {
    testWidgets('golden $name', (tester) async {
      await _pump(tester, size, page);
      await expectLater(
        find.byType(PrismApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
