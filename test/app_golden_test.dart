import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/shell/home_shell.dart';
import 'package:jiejiebox_flutter/features/form/form_page.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:prism_ui/prism_ui.dart';

const _shots = <(Size, String)>[
  (Size(375, 667), 'profiles_375x667'),
  (Size(600, 1024), 'profiles_600x1024'),
  (Size(768, 1024), 'profiles_768x1024'),
  (Size(841, 600), 'profiles_841x600'),
  (Size(1280, 880), 'profiles_1280x880'),
  (Size(390, 844), 'profiles_390x844'),
  (Size(430, 932), 'profiles_430x932'),
  (Size(768, 1024), 'profiles_768x1024'),
  (Size(1024, 1366), 'profiles_1024x1366'),
  (Size(1440, 900), 'profiles_1440x900'),
];

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
  final state = AppState(initialViewSize: size)
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

  for (final (size, name) in _shots) {
    testWidgets('golden $name', (tester) async {
      await _pump(tester, size);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(HomeShell),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }

  testWidgets('golden profiles_1280x880_dark', (tester) async {
    await _pump(tester, const Size(1280, 880), themeMode: ThemeMode.dark);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/profiles_1280x880_dark.png'),
    );
  });

  testWidgets('golden profiles_1280x880_ts14', (tester) async {
    await _pump(tester, const Size(1280, 880), textScale: 1.4);
    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/profiles_1280x880_ts14.png'),
    );
  });

  for (final (size, name) in <(Size, String)>[
    (Size(1280, 880), 'import_1280x880'),
    (Size(375, 667), 'import_375x667'),
  ]) {
    testWidgets('golden $name', (tester) async {
      await _pump(tester, size);
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Link'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).last,
        '{"outbounds":[{"type":"vless","tag":"a"},{"type":"vmess","tag":"b"}]}',
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(FormPage),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }

  for (final (size, name) in <(Size, String)>[
    (Size(1280, 880), 'dashboard_1280x880'),
    (Size(375, 667), 'dashboard_375x667'),
  ]) {
    testWidgets('golden $name', (tester) async {
      final state = await _pump(tester, size);
      state.setPage(PageLabel.dashboard);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(HomeShell),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
