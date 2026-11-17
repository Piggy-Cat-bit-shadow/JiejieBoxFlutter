import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/app.dart';
import 'package:jiejiebox_flutter/features/form/form_page.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';

void main() {
  test('rename keeps id/subtitle and ignores empty names', () {
    final state = AppState(seedProfiles: true);
    state.renameProfile('demo-1', 'Work');
    expect(state.profiles.first.label, 'Work');
    expect(state.profiles.first.id, 'demo-1');
    state.renameProfile('demo-1', '   ');
    expect(state.profiles.first.label, 'Work');
  });

  test('delete removes the draft and clears selection', () {
    final state = AppState(seedProfiles: true);
    final id = state.addProfileDraft(
      label: 'draft',
      subtitle: 'link · 1 nodes · unvalidated',
      content: '{"outbounds":[]}',
    );
    state.selectProfile(id);
    expect(state.drafts.containsKey(id), isTrue);
    state.deleteProfile(id);
    expect(state.profiles.any((profile) => profile.id == id), isFalse);
    expect(state.drafts.containsKey(id), isFalse);
    expect(state.selectedProfileId, isNull);
  });

  testWidgets('two template imports get distinct default labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState(
      seedProfiles: true,
      initialViewSize: const Size(1280, 880),
    );
    await tester.pumpWidget(
      JiejieBoxApp(state: state, locale: const Locale('en', 'US')),
    );
    await tester.pumpAndSettle();

    Future<void> importTemplate() async {
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      tester.widget<FormPage>(find.byType(FormPage)).onSave();
      await tester.pumpAndSettle();
    }

    await importTemplate();
    await importTemplate();
    final labels = state.profiles
        .where((profile) => profile.subtitle.startsWith('template'))
        .map((profile) => profile.label)
        .toList();
    expect(labels.length, 2);
    expect(labels.toSet().length, 2, reason: 'labels must be unique');
  });
}
