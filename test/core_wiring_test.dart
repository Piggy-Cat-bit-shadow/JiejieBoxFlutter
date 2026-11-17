import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/common/enums.dart';
import 'package:jiejiebox_flutter/core/core_bridge.dart';
import 'package:jiejiebox_flutter/core/core_connection.dart';
import 'package:jiejiebox_flutter/features/form/form_page.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';

Future<AppState> _pump(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1280, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    JiejieBoxApp(state: state, locale: const Locale('en', 'US')),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('import records the failed config.check honestly', (
    tester,
  ) async {
    final state = await _pump(
      tester,
      AppState(initialViewSize: const Size(1280, 880)),
    );
    await tester.tap(find.byTooltip('Add profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(EditableText).last,
      '{"outbounds":[{"type":"vless","tag":"a"}]}',
    );
    await tester.pumpAndSettle();
    tester.widget<FormPage>(find.byType(FormPage)).onSave();
    await tester.pumpAndSettle();
    expect(state.profiles.last.subtitle, contains('check unavailable'));
    expect(state.profiles.last.subtitle, contains('unvalidated'));
  });

  testWidgets('start button only exists with a bridge and follows its status', (
    tester,
  ) async {
    final bridge = ScriptedCoreBridge({
      'service.status': {'running': true},
      'service.start': {},
    });
    final state = AppState(
      initialViewSize: const Size(1280, 880),
      coreConnection: CoreConnection(bridge: bridge),
    );
    await _pump(tester, state);
    state.setPage(PageLabel.dashboard);
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(state.connection.state, CoreServiceState.running);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('no bridge shows the reason and no start button', (tester) async {
    final state = await _pump(
      tester,
      AppState(initialViewSize: const Size(1280, 880)),
    );
    state.setPage(PageLabel.dashboard);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Platform bridge is not connected'),
      findsOneWidget,
    );
    expect(find.text('Start'), findsNothing);
    expect(find.text('Core unavailable'), findsOneWidget);
  });
}
