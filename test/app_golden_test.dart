import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/shell/home_shell.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';

const _shots = <(Size, String)>[
  (Size(375, 667), 'profiles_375x667'),
  (Size(600, 1024), 'profiles_600x1024'),
  (Size(768, 1024), 'profiles_768x1024'),
  (Size(841, 600), 'profiles_841x600'),
  (Size(1280, 880), 'profiles_1280x880'),
];

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final bytes = await file.readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<AppState> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(initialViewSize: size);
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
