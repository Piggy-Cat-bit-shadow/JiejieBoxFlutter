import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import '../common/enums.dart';
import '../common/layout.dart';
import '../core/core_connection.dart';

/// A profile row as the UI needs it; ids/revisions are the host's.
class ProfileEntry {
  const ProfileEntry({
    required this.id,
    required this.label,
    required this.subtitle,
    this.revision = '',
    this.kind = 'local',
    this.source = 'local',
    this.updatedAtMillis = 0,
  });

  final String id;
  final String label;
  final String subtitle;
  final String revision;
  final String kind;
  final String source;
  final int updatedAtMillis;
}

/// App-wide UI state. Profiles/licenses come from the host when a bridge is
/// present; without one the list stays empty and every core action reports its
/// reason (no seeded demo profiles in the production constructor).
class AppState extends ChangeNotifier {
  AppState({
    Size initialViewSize = Size.zero,
    CoreConnection? coreConnection,
    bool seedProfiles = false,
  }) : _viewSize = initialViewSize,
       connection = coreConnection ?? CoreConnection() {
    if (seedProfiles) {
      profiles.addAll(const [
        ProfileEntry(
          id: 'demo-1',
          label: 'JiejieBox',
          subtitle: 'local · template',
        ),
        ProfileEntry(id: 'demo-2', label: 'Office', subtitle: 'remote · 6h'),
        ProfileEntry(id: 'demo-3', label: 'Travel', subtitle: 'local'),
      ]);
    }
  }

  Size _viewSize;

  ViewMode get viewMode => getViewMode(_viewSize.width);

  bool get isMobileView => viewMode == ViewMode.mobile;

  final CoreConnection connection;

  double textScale = 1.0;

  ThemeMode themeMode = ThemeMode.system;

  bool floatingNavigationBar = false;

  bool sidebarExpanded = false;

  PageLabel page = PageLabel.profiles;

  final List<ProfileEntry> profiles = <ProfileEntry>[];

  /// Draft contents by profile id, for a local fallback and for A3's store.
  final Map<String, String> drafts = <String, String>{};

  String? selectedProfileId;

  String? lastAddIntent;

  String? lastActionError;

  String? providerRefreshStatus;

  bool _bootstrapped = false;

  bool get isBootstrapped => _bootstrapped;

  ProfileEntry? get currentProfile {
    final id = selectedProfileId;
    if (id == null) return null;
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    if (!connection.isAvailable || !connection.hasRealHost) {
      notifyListeners();
      return;
    }
    try {
      final metas = await connection.listProfiles();
      profiles
        ..clear()
        ..addAll(metas.map(_fromMeta));
      await connection.refresh();
      if (selectedProfileId == null && profiles.isNotEmpty) {
        selectedProfileId = profiles.first.id;
      }
      lastActionError = null;
    } on jb.HostError catch (error) {
      lastActionError = error.message;
    } on Object catch (error) {
      lastActionError = '$error';
    }
    notifyListeners();
  }

  ProfileEntry _fromMeta(jb.ProfileMeta meta) {
    final int bytes = meta.bytes;
    return ProfileEntry(
      id: meta.id,
      label: meta.label,
      subtitle: '${meta.kind} · ${meta.source} · $bytes B',
      revision: meta.revision,
      kind: meta.kind,
      source: meta.source,
      updatedAtMillis: meta.updatedAtMillis,
    );
  }

  Future<void> reloadProfiles() async {
    if (!connection.isAvailable || !connection.hasRealHost) return;
    try {
      final metas = await connection.listProfiles();
      profiles
        ..clear()
        ..addAll(metas.map(_fromMeta));
      if (selectedProfileId != null &&
          !profiles.any((profile) => profile.id == selectedProfileId)) {
        selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
      }
      notifyListeners();
    } on jb.HostError catch (error) {
      lastActionError = error.message;
      notifyListeners();
    }
  }

  void updateViewSize(Size size) {
    if (size == _viewSize) return;
    _viewSize = size;
    notifyListeners();
  }

  void setPage(PageLabel next) {
    if (page == next) return;
    page = next;
    notifyListeners();
  }

  void selectProfile(String id) {
    if (selectedProfileId == id) return;
    final profile = profiles.firstWhere(
      (entry) => entry.id == id,
      orElse: () => const ProfileEntry(id: '', label: '', subtitle: ''),
    );
    if (!connection.isAvailable || !connection.hasRealHost) {
      selectedProfileId = id;
      notifyListeners();
      return;
    }
    final previous = selectedProfileId;
    selectedProfileId = id;
    notifyListeners();
    unawaited(_apply(profile, previous));
  }

  Future<void> _apply(ProfileEntry profile, String? previous) async {
    try {
      final report = await connection.applyProfile(
        id: profile.id,
        revision: profile.revision,
      );
      if (!report.applied) {
        lastActionError = report.coreMessage ?? 'profile was not applied';
        selectedProfileId = previous;
        notifyListeners();
        return;
      }
      lastActionError = null;
      notifyListeners();
    } on jb.HostError catch (error) {
      lastActionError = error.message;
      selectedProfileId = previous;
      notifyListeners();
    }
  }

  Future<bool> startService() async {
    final profile = currentProfile;
    if (profile == null) {
      lastActionError = 'no profile selected';
      notifyListeners();
      return false;
    }
    final ok = await connection.start(
      profileId: profile.id,
      profileRevision: profile.revision,
    );
    lastActionError = ok ? null : connection.reason;
    notifyListeners();
    return ok;
  }

  Future<bool> stopService() async {
    final ok = await connection.stop();
    lastActionError = ok ? null : connection.reason;
    notifyListeners();
    return ok;
  }

  Future<void> refreshProviders() async {
    try {
      final result = await connection.refreshProviders(const []);
      providerRefreshStatus = !result.supported
          ? 'Provider refresh is not supported by this host'
          : result.failed.isEmpty
          ? 'Refreshed ${result.refreshed.length} provider(s)'
          : 'Refreshed ${result.refreshed.length}, failed ${result.failed.length}';
    } on jb.HostError catch (error) {
      providerRefreshStatus = 'Refresh failed: ${error.message}';
    } on Object catch (error) {
      providerRefreshStatus = 'Refresh failed: $error';
    }
    notifyListeners();
  }

  /// Host-backed import: preview, then a validated write. Returns the new id.
  Future<String?> importConfig({
    required String label,
    required String content,
    String kind = 'singbox-json',
  }) async {
    if (!connection.isAvailable || !connection.hasRealHost) {
      return null;
    }
    try {
      final preview = await connection.preview(content);
      if (!preview.ok) {
        lastActionError = preview.message ?? 'preview rejected the content';
        notifyListeners();
        return null;
      }
      final written = await connection.writeProfile(
        label: label,
        content: content,
        kind: kind,
        validate: true,
      );
      await reloadProfiles();
      selectedProfileId = written.id;
      lastActionError = null;
      notifyListeners();
      return written.id;
    } on jb.HostError catch (error) {
      lastActionError = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<void> deleteProfile(String id) async {
    if (connection.isAvailable && connection.hasRealHost) {
      final profile = profiles.firstWhere(
        (entry) => entry.id == id,
        orElse: () => const ProfileEntry(id: '', label: '', subtitle: ''),
      );
      try {
        await connection.deleteProfile(
          id,
          expectedRevision: profile.revision.isEmpty ? null : profile.revision,
        );
      } on jb.HostError catch (error) {
        lastActionError = error.message;
        notifyListeners();
        return;
      }
    }
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return;
    profiles.removeAt(index);
    drafts.remove(id);
    if (selectedProfileId == id) {
      selectedProfileId = null;
    }
    notifyListeners();
  }

  void renameProfile(String id, String label) {
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0 || label.trim().isEmpty) return;
    final old = profiles[index];
    profiles[index] = ProfileEntry(
      id: id,
      label: label.trim(),
      subtitle: old.subtitle,
      revision: old.revision,
      kind: old.kind,
      source: old.source,
      updatedAtMillis: old.updatedAtMillis,
    );
    notifyListeners();
  }

  String addProfileDraft({
    required String label,
    required String subtitle,
    required String content,
  }) {
    final id = 'draft-${DateTime.now().microsecondsSinceEpoch}';
    profiles.add(ProfileEntry(id: id, label: label, subtitle: subtitle));
    drafts[id] = content;
    notifyListeners();
    return id;
  }

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

  void setTextScale(double value) {
    if (textScale == value) return;
    textScale = value;
    notifyListeners();
  }

  void setThemeMode(ThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    notifyListeners();
  }

  void setFloatingNavigationBar(bool value) {
    if (floatingNavigationBar == value) return;
    floatingNavigationBar = value;
    notifyListeners();
  }

  void setSidebarExpanded(bool value) {
    if (sidebarExpanded == value) return;
    sidebarExpanded = value;
    notifyListeners();
  }

  @override
  void dispose() {
    connection.dispose();
    super.dispose();
  }
}

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
