import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/common/system.dart';
import 'package:jiejiebox_flutter/shell/window_header.dart';
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
      ],
    ),
  ], current: 'Proxy');
  store.applyTraffic(
    traffic: const RuntimeTraffic(up: 1024, down: 2048),
    memory: 16 * 1024 * 1024,
    mode: 'rule',
    modes: const ['rule', 'global', 'direct'],
    intranetIp: '192.168.1.9',
    connections: 1,
  );
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

Future<AppState> _pump(
  WidgetTester tester,
  Size size,
  PageLabel page, {
  required TargetPlatform platform,
}) async {
  system.debugPlatformOverride = platform;
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

/// iOS phones must use exactly the Android mobile shell: floating dock, no
/// sidebar, stacked dashboard. Desktop platforms share the sidebar shell;
/// macOS keeps its 28px titled header, Windows the 32px bare one.
void main() {
  setUpAll(() async {
    await _loadFont('Roboto', r'C:\Windows\Fonts\segoeui.ttf');
    await _loadFont('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf');
    // Cupertino themes pick SF on iOS/macOS; map those families to the same
    // local face so the platform goldens can be reviewed instead of tofu.
    for (final family in <String>[
      '.SF UI Text',
      '.SF UI Display',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
      '.AppleSystemUIFont',
    ]) {
      await _loadFont(family, r'C:\Windows\Fonts\segoeui.ttf');
    }
  });

  for (final (size, page, platform, name)
      in <(Size, PageLabel, TargetPlatform, String)>[
        (
          const Size(390, 844),
          PageLabel.dashboard,
          TargetPlatform.iOS,
          'ios_dashboard_390x844',
        ),
        (
          const Size(390, 844),
          PageLabel.proxies,
          TargetPlatform.iOS,
          'ios_proxies_390x844',
        ),
        (
          const Size(390, 844),
          PageLabel.connections,
          TargetPlatform.iOS,
          'ios_connections_390x844',
        ),
        (
          const Size(1280, 880),
          PageLabel.dashboard,
          TargetPlatform.macOS,
          'macos_dashboard_1280x880',
        ),
        (
          const Size(1280, 880),
          PageLabel.dashboard,
          TargetPlatform.windows,
          'windows_dashboard_1280x880',
        ),
      ]) {
    testWidgets('platform $name', (tester) async {
      await _pump(tester, size, page, platform: platform);
      await expectLater(
        find.byType(PrismApp),
        matchesGoldenFile('goldens/$name.png'),
      );
      system.debugPlatformOverride = null;
    });
  }

  testWidgets('iOS phone uses the Android mobile shell', (tester) async {
    await _pump(
      tester,
      const Size(390, 844),
      PageLabel.dashboard,
      platform: TargetPlatform.iOS,
    );
    expect(find.byType(NavigationDock), findsOneWidget);
    expect(find.byType(NavigationSidebar), findsNothing);
    expect(find.byType(WindowHeader), findsNothing);
    system.debugPlatformOverride = null;
  });

  testWidgets('macOS desktop uses the sidebar traffic-light area', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1280, 880),
      PageLabel.dashboard,
      platform: TargetPlatform.macOS,
    );
    expect(find.byType(NavigationSidebar), findsOneWidget);
    // Wide macOS draws the traffic lights over the sidebar, exactly like
    // FlClash; the extra header exists only in the narrow window.
    expect(find.byType(WindowHeader), findsNothing);
    system.debugPlatformOverride = null;
  });

  testWidgets('macOS narrow window draws the 28px titled header', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(390, 844),
      PageLabel.dashboard,
      platform: TargetPlatform.macOS,
    );
    expect(find.byType(WindowHeader), findsOneWidget);
    expect(tester.getSize(find.byType(WindowHeader)).height, 28);
    expect(find.text('JiejieBox'), findsWidgets);
    system.debugPlatformOverride = null;
  });

  testWidgets('Windows desktop uses the 32px header without a title', (
    tester,
  ) async {
    await _pump(
      tester,
      const Size(1280, 880),
      PageLabel.dashboard,
      platform: TargetPlatform.windows,
    );
    final header = tester.getSize(find.byType(WindowHeader));
    expect(header.height, 32);
    system.debugPlatformOverride = null;
  });
}
