import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/features/form/form_page.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';

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

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add profile'));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  // Invoke the page's confirmation callback: the check button lives in the
  // Prism app bar and is not addressable by tooltip in the test harness.
  final page = tester.widget<FormPage>(find.byType(FormPage));
  page.onSave();
  await tester.pumpAndSettle();
}

Future<void> _openLinkSheet(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(find.text('Link'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('add menu shows upstream entries plus clipboard/template', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 880));
    await _openMenu(tester);
    expect(find.text('QR code'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);
    expect(find.text('Import from clipboard'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
  });

  testWidgets('invalid import is refused with a readable reason', (
    tester,
  ) async {
    final state = await _pump(tester, const Size(1280, 880));
    await _openLinkSheet(tester);
    expect(find.byType(FormPage), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'plain words');
    await _submit(tester);
    expect(find.textContaining('Unrecognized'), findsWidgets);
    expect(state.profiles.length, 3);
    expect(state.drafts, isEmpty);
  });

  testWidgets('valid sing-box JSON becomes an unvalidated draft', (
    tester,
  ) async {
    final state = await _pump(tester, const Size(1280, 880));
    await _openLinkSheet(tester);
    await tester.enterText(
      find.byType(EditableText).last,
      '{"outbounds":[{"type":"vless","tag":"a"}]}',
    );
    await tester.pumpAndSettle();
    expect(find.text('sing-box JSON'), findsOneWidget);
    await _submit(tester);
    expect(state.profiles.length, 4);
    expect(state.drafts.length, 1);
    expect(state.profiles.last.subtitle, contains('unvalidated'));
  });

  testWidgets('clipboard import reads text but only saves after confirm', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'ss://YWVzLTEyOC1nY206cGFzcw@1.1.1.1:8388#node'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final state = await _pump(tester, const Size(1280, 880));
    await _openMenu(tester);
    await tester.tap(find.text('Import from clipboard'));
    await tester.pumpAndSettle();
    expect(find.text('Share links'), findsOneWidget);
    expect(state.profiles.length, 3, reason: 'no save before confirm');
    await _submit(tester);
    expect(state.profiles.length, 4);
    expect(state.drafts.length, 1);
  });

  testWidgets('default template creates a draft without touching JSON', (
    tester,
  ) async {
    final state = await _pump(tester, const Size(1280, 880));
    await _openMenu(tester);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.text('sing-box JSON'), findsOneWidget);
    await _submit(tester);
    expect(state.profiles.length, 4);
    expect(state.profiles.last.subtitle, contains('template'));
  });

  testWidgets('import sheet renders at the small viewport without overflow', (
    tester,
  ) async {
    await _pump(tester, const Size(375, 667));
    await _openLinkSheet(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(FormPage), findsOneWidget);
  });
}
