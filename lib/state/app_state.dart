import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../common/enums.dart';
import '../common/layout.dart';

/// A profile row as the UI needs it. The real model (revision, file path,
/// provider references) arrives with the A2 data layer; this shape is the
/// minimum the ported card renders.
class ProfileEntry {
  const ProfileEntry({
    required this.id,
    required this.label,
    required this.subtitle,
  });

  final int id;
  final String label;
  final String subtitle;
}

/// The single app-wide state for P1. It replaces FlClash's Riverpod graph for
/// the shell only; pages read it through [AppStateScope].
///
/// Deliberately no core/proxy status lives here: nothing may render a
/// "connected"/"updated" state until the A2 bridge provides one.
class AppState extends ChangeNotifier {
  AppState({Size initialViewSize = Size.zero})
    : _viewSize = initialViewSize;

  Size _viewSize;

  Size get viewSize => _viewSize;

  ViewMode get viewMode => getViewMode(_viewSize.width);

  bool get isMobileView => viewMode == ViewMode.mobile;

  double textScale = 1.0;

  ThemeMode themeMode = ThemeMode.system;

  bool floatingNavigationBar = false;

  bool sidebarExpanded = false;

  PageLabel page = PageLabel.profiles;

  /// P1 fixture: replaced by the host-side profile store in A2. It is data the
  /// user owns, never a simulated connection state.
  final List<ProfileEntry> profiles = <ProfileEntry>[
    const ProfileEntry(id: 1, label: 'JiejieBox', subtitle: 'local · template'),
    const ProfileEntry(id: 2, label: 'Office', subtitle: 'remote · 6h'),
    const ProfileEntry(id: 3, label: 'Travel', subtitle: 'local'),
  ];

  int? selectedProfileId;

  /// Draft contents by profile id. Kept in memory only in P2; the store moves
  /// here in A3. Nothing is validated by the kernel yet.
  final Map<int, String> drafts = <int, String>{};

  int addProfileDraft({
    required String label,
    required String subtitle,
    required String content,
  }) {
    final id = profiles.isEmpty
        ? 1
        : profiles.map((profile) => profile.id).reduce((a, b) => a > b ? a : b) + 1;
    profiles.add(ProfileEntry(id: id, label: label, subtitle: subtitle));
    drafts[id] = content;
    notifyListeners();
    return id;
  }

  void renameProfile(int id, String label) {
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0 || label.trim().isEmpty) {
      return;
    }
    profiles[index] = ProfileEntry(
      id: id,
      label: label.trim(),
      subtitle: profiles[index].subtitle,
    );
    notifyListeners();
  }

  void deleteProfile(int id) {
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) {
      return;
    }
    profiles.removeAt(index);
    drafts.remove(id);
    if (selectedProfileId == id) {
      selectedProfileId = null;
    }
    notifyListeners();
  }

  /// Set when an AddProfileMenu entry is chosen; A2 consumes it. Keeping the
  /// intent explicit avoids a "button that silently does nothing" ambiguity.
  String? lastAddIntent;

  void updateViewSize(Size size) {
    if (size == _viewSize) {
      return;
    }
    _viewSize = size;
    notifyListeners();
  }

  void setPage(PageLabel next) {
    if (page == next) return;
    page = next;
    notifyListeners();
  }

  void selectProfile(int id) {
    if (selectedProfileId == id) return;
    selectedProfileId = id;
    notifyListeners();
  }

  void setSidebarExpanded(bool value) {
    if (sidebarExpanded == value) return;
    sidebarExpanded = value;
    notifyListeners();
  }

  void setThemeMode(ThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    notifyListeners();
  }

  void setTextScale(double value) {
    if (textScale == value) return;
    textScale = value;
    notifyListeners();
  }

  void setFloatingNavigationBar(bool value) {
    if (floatingNavigationBar == value) return;
    floatingNavigationBar = value;
    notifyListeners();
  }

  /// Replaces the profile list; A2's store and the empty-state test both use it.
  void replaceProfiles(List<ProfileEntry> next) {
    profiles
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void noteAddIntent(String intent) {
    lastAddIntent = intent;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
  }
}

/// Inherited access to [AppState]; the shell and pages rebuild on change.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'No AppStateScope above this context.');
    return scope!.notifier!;
  }

  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'No AppStateScope above this context.');
    return scope!.notifier!;
  }
}
