import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode;
import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import '../common/enums.dart';
import '../common/layout.dart';
import '../core/core_connection.dart';
import '../features/import/import_classifier.dart';

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

  bool systemProxyEnabled = false;
  bool autostartEnabled = false;

  bool get canSystemProxy => connection.capabilities?.systemProxy ?? false;
  bool get canAutostart => connection.capabilities?.autostart ?? false;
  bool get canTray => connection.capabilities?.tray ?? false;

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
      await connection.refreshCapabilities();
      if (selectedProfileId == null && profiles.isNotEmpty) {
        selectedProfileId = profiles.first.id;
      }
      await _loadDesktopState();
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
      await _syncTray();
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
    await _syncTray();
    notifyListeners();
    return ok;
  }

  Future<bool> stopService() async {
    final ok = await connection.stop();
    systemProxyEnabled = false;
    lastActionError = ok ? null : connection.reason;
    await _syncTray();
    notifyListeners();
    return ok;
  }

  Future<void> _loadDesktopState() async {
    if (!connection.hasRealHost) return;
    try {
      if (canSystemProxy) {
        final status = await connection.systemProxyStatus(
          port: connection.runtimeStatus?.proxyPort ?? 0,
        );
        systemProxyEnabled = status.ourProxyActive;
        if (status.staleFromPreviousRun) {
          // The previous process died before restoring WinINet. Restore now
          // instead of leaving every browser pointed at a dead port.
          await connection.applySystemProxy(enabled: false, port: 0);
          systemProxyEnabled = false;
        }
      }
      if (canAutostart) {
        autostartEnabled = await connection.autoLaunchStatus();
      }
      await _syncTray();
    } on Object {
      // Capability queries are best-effort; a missing system integration must
      // not stop profile/service startup.
    }
  }

  Future<void> _syncTray() async {
    if (!canTray) return;
    try {
      await connection.updateTray(
        running: connection.state == CoreServiceState.running,
        mode: connection.runtimeStatus?.mode ?? 'proxy',
        proxyPort: connection.runtimeStatus?.proxyPort ?? 0,
      );
    } on Object {
      // Tray is optional shell integration.
    }
  }

  Future<void> setSystemProxy(bool enabled) async {
    if (!canSystemProxy) return;
    if (enabled && connection.state != CoreServiceState.running) {
      lastActionError = 'Start the core before enabling the system proxy';
      notifyListeners();
      return;
    }
    try {
      final ok = await connection.applySystemProxy(
        enabled: enabled,
        port: connection.runtimeStatus?.proxyPort ?? 0,
        bypass: const <String>['<local>'],
      );
      systemProxyEnabled = enabled && ok;
      lastActionError = ok
          ? null
          : enabled
          ? 'System proxy was not enabled'
          : 'System proxy was not disabled';
    } on jb.HostError catch (error) {
      lastActionError = error.message;
    }
    notifyListeners();
  }

  Future<void> setAutostart(bool enabled) async {
    if (!canAutostart) return;
    try {
      autostartEnabled = await connection.setAutoLaunch(enabled);
      lastActionError = null;
    } on jb.HostError catch (error) {
      lastActionError = error.message;
    }
    notifyListeners();
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
    return _storeImported(label: label, text: content, kind: kind);
  }

  /// Fetches a subscription URL, classifies the body and stores the resulting
  /// profile. The body is capped so a hostile endpoint cannot exhaust memory.
  Future<String?> importSubscription({
    required String url,
    required String label,
  }) async {
    if (!connection.isAvailable || !connection.hasRealHost) return null;
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      reportError('Subscription URL must be http(s)');
      return null;
    }
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final HttpClientRequest request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'JiejieBox/0.1');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        reportError('Subscription HTTP ${response.statusCode}');
        return null;
      }
      const int maxBytes = 8 * 1024 * 1024;
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response.timeout(
        const Duration(seconds: 30),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          reportError('Subscription is larger than 8 MiB');
          return null;
        }
      }
      final String body = utf8.decode(bytes, allowMalformed: true);
      final preview = classifyImport(body);
      if (preview.format == ImportFormat.subscriptionUrl || !preview.isUsable) {
        reportError(
          preview.hints.isEmpty
              ? 'The subscription body is not a config or node list'
              : preview.hints.first,
        );
        return null;
      }
      return await _storeImported(
        label: label.trim().isEmpty ? _subscriptionLabel(uri) : label,
        text: preview.text,
        kind: _kindFor(preview.format),
      );
    } on Object catch (error) {
      reportError('Subscription fetch failed: $error');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<String?> _storeImported({
    required String label,
    required String text,
    required String kind,
  }) async {
    try {
      final preview = await connection.preview(text);
      if (!preview.ok) {
        lastActionError = preview.message ?? 'preview rejected the content';
        notifyListeners();
        return null;
      }
      String stored = text;
      String storedKind = kind;
      final bool mobileTun = Platform.isAndroid || Platform.isIOS;
      if (kind != 'singbox-json' && preview.items.isNotEmpty) {
        final composed = composeImportedConfig(
          preview,
          listenPort: await _freeLoopbackPort(),
          tun: mobileTun,
        );
        if (composed == null) {
          lastActionError = 'the node list could not be assembled';
          notifyListeners();
          return null;
        }
        stored = composed;
        storedKind = 'singbox-json';
      }
      if (mobileTun) {
        stored = _withTunInbound(stored);
      }
      final checked = await connection.checkConfig(stored);
      if (!checked.ok) {
        lastActionError = checked.message ?? 'the core rejected the profile';
        notifyListeners();
        return null;
      }
      final written = await connection.writeProfile(
        label: label,
        content: stored,
        kind: storedKind,
        validate: true,
      );
      await reloadProfiles();
      final previous = selectedProfileId;
      selectedProfileId = written.id;
      lastActionError = null;
      notifyListeners();
      if (connection.state == CoreServiceState.running) {
        final entry = profiles.firstWhere(
          (profile) => profile.id == written.id,
          orElse: () => ProfileEntry(
            id: written.id,
            label: label,
            subtitle: storedKind,
            revision: written.revision,
          ),
        );
        await _apply(entry, previous);
      }
      return written.id;
    } on jb.HostError catch (error) {
      lastActionError = error.message;
      notifyListeners();
      return null;
    } on Object catch (error) {
      lastActionError = '$error';
      notifyListeners();
      return null;
    }
  }

  Future<void> deleteProfile(String id) async {
    final isSelected = selectedProfileId == id;
    if (connection.isAvailable &&
        connection.hasRealHost &&
        isSelected &&
        connection.state == CoreServiceState.running) {
      final stopped = await connection.stop();
      if (!stopped) {
        lastActionError = connection.reason ?? 'could not stop the service';
        notifyListeners();
        return;
      }
    }
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
      selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
    }
    notifyListeners();
  }

  Future<void> renameProfile(String id, String label) async {
    final index = profiles.indexWhere((profile) => profile.id == id);
    if (index < 0 || label.trim().isEmpty) return;
    final old = profiles[index];
    final nextLabel = label.trim();
    if (old.label == nextLabel) return;
    if (connection.isAvailable &&
        connection.hasRealHost &&
        old.revision.isNotEmpty) {
      try {
        final document = await connection.readProfile(id);
        await connection.writeProfile(
          id: id,
          label: nextLabel,
          content: utf8.decode(document.content),
          kind: old.kind,
          expectedRevision: document.revision,
          validate: false,
        );
        await reloadProfiles();
        lastActionError = null;
        notifyListeners();
        return;
      } on jb.HostError catch (error) {
        lastActionError = error.message;
        notifyListeners();
        return;
      } on Object catch (error) {
        lastActionError = '$error';
        notifyListeners();
        return;
      }
    }
    profiles[index] = ProfileEntry(
      id: id,
      label: nextLabel,
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

  void reportError(String message) {
    lastActionError = message;
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

String _kindFor(ImportFormat format) => switch (format) {
  ImportFormat.singBoxJson => 'singbox-json',
  ImportFormat.clashYaml => 'clash-yaml',
  ImportFormat.sip008 => 'sip008',
  _ => 'link-list',
};

String _withTunInbound(String config) {
  try {
    final decoded = jsonDecode(config);
    if (decoded is! Map) return config;
    final map = decoded.cast<String, Object?>();
    final inbounds = <Object?>[
      for (final item
          in (map['inbounds'] as List<Object?>?) ?? const <Object?>[])
        item,
    ];
    final hasTun = inbounds.any((item) => item is Map && item['type'] == 'tun');
    if (hasTun) return config;
    inbounds.add(<String, Object?>{
      'type': 'tun',
      'tag': 'tun-in',
      'address': <String>['198.18.0.1/30'],
      'mtu': 9000,
      'auto_route': true,
      'strict_route': false,
      'stack': 'mixed',
    });
    map['inbounds'] = inbounds;
    final route = (map['route'] as Map<Object?, Object?>?)
        ?.cast<String, Object?>();
    if (route != null && !route.containsKey('auto_detect_interface')) {
      route['auto_detect_interface'] = true;
      map['route'] = route;
    }
    return jsonEncode(map);
  } on Object {
    return config;
  }
}

String _subscriptionLabel(Uri uri) {
  final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
  return host.isEmpty ? 'Subscription' : host;
}

Future<int> _freeLoopbackPort() async {
  try {
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();
    return port;
  } on Object {
    return 7890;
  }
}

/// Turns parsed nodes into a complete sing-box profile. The kernel's preview
/// gives each node's own JSON; this adds the minimum routing/inbound envelope so
/// a share-link or Clash list can actually be started.
String? composeImportedConfig(
  jb.PreviewResult preview, {
  int listenPort = 7890,
  bool tun = false,
}) {
  final outbounds = <Map<String, Object?>>[];
  final endpoints = <Map<String, Object?>>[];
  for (final item in preview.items) {
    if (item.content.isEmpty) continue;
    try {
      final decoded = jsonDecode(item.content);
      if (decoded is! Map) continue;
      final node = decoded.cast<String, Object?>();
      if (item.endpoint) {
        endpoints.add(node);
      } else {
        outbounds.add(node);
      }
    } on Object {
      continue;
    }
  }
  if (outbounds.isEmpty && endpoints.isEmpty) return null;
  final tags = <Object?>{
    for (final node in <Map<String, Object?>>[...outbounds, ...endpoints])
      node['tag'],
  };
  final Map<String, Object?>? proxy = outbounds
      .cast<Map<String, Object?>>()
      .firstWhere(
        (node) => !<String>{'direct', 'block', 'dns'}.contains(node['type']),
        orElse: () => const <String, Object?>{},
      );
  final runner =
      proxy?['tag'] ?? (outbounds.isNotEmpty ? outbounds.first['tag'] : null);
  final directTag = tags.contains('direct') ? 'direct-out' : 'direct';
  outbounds.add(<String, Object?>{'type': 'direct', 'tag': directTag});
  final config = <String, Object?>{
    'log': <String, Object?>{'level': 'info'},
    'inbounds': <Object?>[
      tun
          ? <String, Object?>{
              'type': 'tun',
              'tag': 'tun-in',
              'address': <String>['198.18.0.1/30'],
              'mtu': 9000,
              'auto_route': true,
              'strict_route': false,
              'stack': 'mixed',
            }
          : <String, Object?>{
              'type': 'mixed',
              'tag': 'mixed-in',
              'listen': '127.0.0.1',
              'listen_port': listenPort,
            },
    ],
    'outbounds': outbounds,
    if (endpoints.isNotEmpty) 'endpoints': endpoints,
    'route': <String, Object?>{'final': runner ?? directTag},
  };
  return jsonEncode(config);
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
