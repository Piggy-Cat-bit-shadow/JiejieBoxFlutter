import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/shell/home_shell.dart';
import 'package:jiejiebox_flutter/shell/window_header.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:prism_ui/prism_ui.dart';

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
  Size size, {
  double textScale = 1.0,
  ThemeMode themeMode = ThemeMode.system,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(seedProfiles: true, initialViewSize: size)
    ..textScale = textScale
    ..themeMode = themeMode;
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

  testWidgets('empty profile list renders the upstream null status', (
    tester,
  ) async {
    final state = await _pump(tester, const Size(1280, 880));
    state.replaceProfiles(const []);
    await tester.pumpAndSettle();
    expect(find.byType(NullStatus), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop title bar keeps the measured height', (tester) async {
    await _pump(tester, const Size(1280, 880));
    expect(find.byType(WindowHeader), findsOneWidget);
    expect(tester.getSize(find.byType(WindowHeader)).height, 32);
  });

  testWidgets('mobile shell has no title bar', (tester) async {
    await _pump(tester, const Size(375, 667));
    // Windows still draws its own chrome at a narrow window (FlClash does too);
    // the title bar belongs to the desktop host, so it stays here.
    expect(find.byType(WindowHeader), findsOneWidget);
  });

  testWidgets('dark theme renders without exceptions', (tester) async {
    await _pump(tester, const Size(390, 844), themeMode: ThemeMode.dark);
    expect(tester.takeException(), isNull);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets(
    'text scale 1.4 at desktop keeps profile columns and no overflow',
    (tester) async {
      await _pump(tester, const Size(1280, 880), textScale: 1.4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching to dashboard keeps the shell', (tester) async {
    final state = await _pump(tester, const Size(1280, 880));
    state.setPage(PageLabel.dashboard);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
