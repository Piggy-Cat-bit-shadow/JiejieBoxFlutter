import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:prism_ui/prism_ui.dart';

/// Viewport -> expected profile columns, from
/// OUTPUT/A/P0/evidence/screen_matrix.csv (textScale 1.0). Hard-coded on
/// purpose: the test must not re-derive the value with the same function it is
/// checking.
const _viewports = <(Size, int)>[
  (Size(375, 667), 1),
  (Size(600, 1024), 1),
  (Size(601, 1024), 1),
  (Size(840, 600), 2),
  (Size(841, 600), 2),
  (Size(1280, 880), 3),
  (Size(380, 400), 1),
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = AppState(seedProfiles: true, initialViewSize: size)
    ..textScale = textScale;
  await tester.pumpWidget(JiejieBoxApp(state: state));
  await tester.pumpAndSettle();
  return state;
}

int _profileColumns(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byType(GridView));
  final delegate =
      grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

void main() {
  setUpAll(() async {
    await _loadFont('Roboto', r'C:\Windows\Fonts\segoeui.ttf');
    await _loadFont('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf');
  });

  for (final (size, expectedColumns) in _viewports) {
    testWidgets(
      'shell and profile grid at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await _pump(tester, size);
        expect(tester.takeException(), isNull);
        expect(_profileColumns(tester), expectedColumns);
        final isMobile = size.width <= 600;
        expect(
          find.byType(NavigationBar),
          isMobile ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationSidebar),
          isMobile ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  testWidgets('text scale 1.4 keeps the grid without overflow', (tester) async {
    final state = await _pump(tester, const Size(601, 1024), textScale: 1.4);
    expect(state.textScale, 1.4);
    expect(tester.takeException(), isNull);
    expect(_profileColumns(tester), 1);
  });

  testWidgets('switching page keeps the shell', (tester) async {
    final state = await _pump(tester, const Size(1280, 880));
    state.setPage(PageLabel.tools);
    await tester.pumpAndSettle();
    expect(state.page, PageLabel.tools);
    expect(tester.takeException(), isNull);
  });
}
