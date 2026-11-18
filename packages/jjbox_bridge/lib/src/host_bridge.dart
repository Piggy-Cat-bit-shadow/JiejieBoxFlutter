/// The typed Dart facade over the bridge contract (`jjbox/host`).
///
/// One method per contract entry; no stringly-typed calls leak to the UI. The
/// transport is injected so tests, the fake host and the real MethodChannel
/// share the same bridge semantics.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'capabilities.dart';
import 'envelope.dart';
import 'errors.dart';

/// Where a bridge command goes. Implemented by the MethodChannel transport and
/// by the test fake.
abstract class HostTransport {
  Future<HostResponse> send(HostRequest request);

  Stream<HostCallback> get callbacks;

  Future<void> dispose();
}

/// Wire names, kept in one list so a generator can compare them with the
/// contract JSON.
abstract final class BridgeMethod {
  static const String hostCapabilities = 'host.capabilities';
  static const String coreCapabilities = 'core.capabilities';
  static const String hostSetup = 'host.setup';
  static const String hostShutdown = 'host.shutdown';
  static const String serviceStart = 'service.start';
  static const String serviceStop = 'service.stop';
  static const String serviceStatus = 'service.status';
  static const String configCheck = 'config.check';
  static const String configFormat = 'config.format';
  static const String configPreview = 'config.preview';
  static const String profileList = 'profile.list';
  static const String profileRead = 'profile.read';
  static const String profileWrite = 'profile.write';
  static const String profileDelete = 'profile.delete';
  static const String profileRestore = 'profile.restore';
  static const String profileApply = 'profile.apply';
  static const String providerRefresh = 'provider.refresh';
  static const String systemProxyApply = 'systemProxy.apply';
  static const String systemProxyStatus = 'systemProxy.status';
  static const String tunRequestPermission = 'tun.requestPermission';
  static const String qrScan = 'qr.scan';
  static const String filePickConfig = 'file.pickConfig';
  static const String clipboardReadCandidate = 'clipboard.readCandidate';
  static const String appSetAutoLaunch = 'app.setAutoLaunch';
  static const String appAutoLaunchStatus = 'app.autoLaunchStatus';
  static const String trayUpdate = 'tray.update';

  static const List<String> all = <String>[
    hostCapabilities,
    coreCapabilities,
    hostSetup,
    hostShutdown,
    serviceStart,
    serviceStop,
    serviceStatus,
    configCheck,
    configFormat,
    configPreview,
    profileList,
    profileRead,
    profileWrite,
    profileDelete,
    profileRestore,
    profileApply,
    providerRefresh,
    systemProxyApply,
    systemProxyStatus,
    tunRequestPermission,
    qrScan,
    filePickConfig,
    clipboardReadCandidate,
    appSetAutoLaunch,
    appAutoLaunchStatus,
    trayUpdate,
  ];
}

/// The setup payload; mirrors libbox `SetupOptions` one to one.
class SetupRequest {
  const SetupRequest({
    required this.basePath,
    required this.workingPath,
    required this.tempPath,
    required this.appVersion,
    required this.appMarketingVersion,
    this.logMaxLines = 1000,
    this.debug = false,
    this.commandServerSecret = '',
    this.oomKillerEnabled = false,
    this.oomMemoryLimitBytes = 0,
    this.platformMetadata = '{}',
  });

  final String basePath;
  final String workingPath;
  final String tempPath;
  final String appVersion;
  final String appMarketingVersion;
  final int logMaxLines;
  final bool debug;
  final String commandServerSecret;
  final bool oomKillerEnabled;
  final int oomMemoryLimitBytes;
  final String platformMetadata;

  Map<String, Object?> toArgs() => <String, Object?>{
    'basePath': basePath,
    'workingPath': workingPath,
    'tempPath': tempPath,
    'appVersion': appVersion,
    'appMarketingVersion': appMarketingVersion,
    'logMaxLines': logMaxLines,
    'debug': debug,
    'commandServerSecret': commandServerSecret,
    'oomKillerEnabled': oomKillerEnabled,
    'oomMemoryLimitBytes': oomMemoryLimitBytes,
    'platformMetadata': platformMetadata,
  };
}

class StartAck {
  const StartAck({required this.accepted, required this.revision});

  factory StartAck.fromJson(Map<String, Object?> json) => StartAck(
    accepted: json['accepted'] as bool? ?? false,
    revision: (json['revision'] as num?)?.toInt() ?? 0,
  );

  final bool accepted;
  final int revision;
}

/// The authoritative runtime view; `running` here means evidence, not an ack.
class RuntimeStatus {
  const RuntimeStatus({
    required this.state,
    required this.revision,
    this.sinceMillis = 0,
    this.mode = '',
    this.tunActive = false,
    this.proxyPort,
    this.permission = 'unrequested',
    this.lastError,
  });

  factory RuntimeStatus.fromJson(Map<String, Object?> json) {
    return RuntimeStatus(
      state: json['state'] as String? ?? 'idle',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      sinceMillis: (json['sinceMillis'] as num?)?.toInt() ?? 0,
      mode: json['mode'] as String? ?? '',
      tunActive: json['tunActive'] as bool? ?? false,
      proxyPort: (json['proxyPort'] as num?)?.toInt(),
      permission: json['permission'] as String? ?? 'unrequested',
      lastError: json['lastError'] == null
          ? null
          : HostError.fromJson(
              (json['lastError'] as Map<Object?, Object?>)
                  .cast<String, Object?>(),
            ),
    );
  }

  final String state;
  final int revision;
  final int sinceMillis;
  final String mode;
  final bool tunActive;
  final int? proxyPort;
  final String permission;
  final HostError? lastError;

  bool get isRunning => state == 'running';
}

class ConfigCheckResult {
  const ConfigCheckResult({
    required this.ok,
    this.code,
    this.message,
    this.normalizedKind,
  });

  factory ConfigCheckResult.fromJson(Map<String, Object?> json) =>
      ConfigCheckResult(
        ok: json['ok'] as bool? ?? false,
        code: json['code'] as String?,
        message: json['message'] as String?,
        normalizedKind: json['normalizedKind'] as String?,
      );

  final bool ok;
  final String? code;
  final String? message;
  final String? normalizedKind;
}

/// A preview item: `content` is deliberately absent because it carries
/// credentials; a host must never put it on the wire.
class PreviewItem {
  const PreviewItem({
    required this.tag,
    required this.type,
    required this.endpoint,
    this.content = '',
  });

  factory PreviewItem.fromJson(Map<String, Object?> json) => PreviewItem(
    tag: json['tag'] as String? ?? '',
    type: json['type'] as String? ?? '',
    endpoint: json['endpoint'] as bool? ?? false,
    content: json['content'] as String? ?? '',
  );

  final String tag;
  final String type;
  final bool endpoint;
  final String content;
}

class PreviewSkip {
  const PreviewSkip({required this.line, required this.reason});

  factory PreviewSkip.fromJson(Map<String, Object?> json) => PreviewSkip(
    line: (json['line'] as num?)?.toInt() ?? 0,
    reason: json['reason'] as String? ?? '',
  );

  final int line;
  final String reason;
}

class PreviewResult {
  const PreviewResult({
    required this.ok,
    this.format,
    this.count = 0,
    this.declared = 0,
    this.base64 = false,
    this.items = const <PreviewItem>[],
    this.skipped = const <PreviewSkip>[],
    this.code,
    this.message,
  });

  factory PreviewResult.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? error =
        (json['error'] as Map<Object?, Object?>?)?.cast<String, Object?>();
    return PreviewResult(
      ok: json['ok'] as bool? ?? false,
      format: json['format'] as String?,
      count: (json['count'] as num?)?.toInt() ?? 0,
      declared: (json['declared'] as num?)?.toInt() ?? 0,
      base64: json['base64'] as bool? ?? false,
      items: <PreviewItem>[
        for (final Object? item
            in (json['items'] as List<Object?>?) ?? const <Object?>[])
          if (item is Map<Object?, Object?>)
            PreviewItem.fromJson(item.cast<String, Object?>()),
      ],
      skipped: <PreviewSkip>[
        for (final Object? item
            in (json['skipped'] as List<Object?>?) ?? const <Object?>[])
          if (item is Map<Object?, Object?>)
            PreviewSkip.fromJson(item.cast<String, Object?>()),
      ],
      code: error?['code'] as String?,
      message: error?['message'] as String?,
    );
  }

  final bool ok;
  final String? format;
  final int count;
  final int declared;
  final bool base64;
  final List<PreviewItem> items;
  final List<PreviewSkip> skipped;
  final String? code;
  final String? message;
}

class ProfileMeta {
  const ProfileMeta({
    required this.id,
    required this.label,
    this.kind = 'local',
    this.revision = '',
    this.updatedAtMillis = 0,
    this.source = 'local',
    this.bytes = 0,
  });

  factory ProfileMeta.fromJson(Map<String, Object?> json) => ProfileMeta(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    kind: json['kind'] as String? ?? 'local',
    revision: json['revision'] as String? ?? '',
    updatedAtMillis: (json['updatedAtMillis'] as num?)?.toInt() ?? 0,
    source: json['source'] as String? ?? 'local',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String label;
  final String kind;
  final String revision;
  final int updatedAtMillis;
  final String source;
  final int bytes;
}

class ProfileContent {
  const ProfileContent({
    required this.id,
    required this.content,
    required this.revision,
    this.updatedAtMillis = 0,
  });

  factory ProfileContent.fromJson(Map<String, Object?> json) {
    final String encoded =
        json['content'] as String? ?? (json['contentB64'] as String? ?? '');
    return ProfileContent(
      id: json['id'] as String? ?? '',
      content: base64Decode(encoded),
      revision: json['revision'] as String? ?? '',
      updatedAtMillis: (json['updatedAtMillis'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final Uint8List content;
  final String revision;
  final int updatedAtMillis;
}

class ProfileWriteResult {
  const ProfileWriteResult({
    required this.id,
    required this.revision,
    this.validated = false,
    this.bytes = 0,
  });

  factory ProfileWriteResult.fromJson(Map<String, Object?> json) =>
      ProfileWriteResult(
        id: json['id'] as String? ?? '',
        revision: json['revision'] as String? ?? '',
        validated: json['validated'] as bool? ?? false,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String revision;
  final bool validated;
  final int bytes;
}

class ApplyReport {
  const ApplyReport({
    required this.applied,
    this.requestId = '',
    this.coreMessage,
    this.switchedAtMillis,
  });

  factory ApplyReport.fromJson(Map<String, Object?> json) => ApplyReport(
    applied: json['applied'] as bool? ?? false,
    requestId: json['requestId'] as String? ?? '',
    coreMessage: json['coreMessage'] as String?,
    switchedAtMillis: (json['switchedAtMillis'] as num?)?.toInt(),
  );

  final bool applied;
  final String requestId;
  final String? coreMessage;
  final int? switchedAtMillis;
}

class ProviderRefreshResult {
  const ProviderRefreshResult({
    required this.supported,
    this.refreshed = const <String>[],
    this.failed = const <String, String>{},
    this.durationMillis = 0,
  });

  factory ProviderRefreshResult.fromJson(Map<String, Object?> json) {
    final Map<String, String> failed = <String, String>{};
    for (final Object? entry
        in (json['failed'] as List<Object?>?) ?? const <Object?>[]) {
      if (entry is Map<Object?, Object?>) {
        final Map<String, Object?> row = entry.cast<String, Object?>();
        failed[row['tag'] as String? ?? ''] = row['message'] as String? ?? '';
      }
    }
    return ProviderRefreshResult(
      supported: json['supported'] as bool? ?? false,
      refreshed: <String>[
        for (final Object? tag
            in (json['refreshed'] as List<Object?>?) ?? const <Object?>[])
          if (tag is String) tag,
      ],
      failed: failed,
      durationMillis: (json['durationMillis'] as num?)?.toInt() ?? 0,
    );
  }

  final bool supported;
  final List<String> refreshed;
  final Map<String, String> failed;
  final int durationMillis;
}

class SystemProxyStatus {
  const SystemProxyStatus({
    required this.ourProxyActive,
    this.port,
    this.staleFromPreviousRun = false,
  });

  factory SystemProxyStatus.fromJson(Map<String, Object?> json) =>
      SystemProxyStatus(
        ourProxyActive: json['ourProxyActive'] as bool? ?? false,
        port: (json['port'] as num?)?.toInt(),
        staleFromPreviousRun: json['staleFromPreviousRun'] as bool? ?? false,
      );

  final bool ourProxyActive;
  final int? port;
  final bool staleFromPreviousRun;
}

class PermissionResult {
  const PermissionResult({
    required this.status,
    this.asked = false,
    this.detail,
  });

  factory PermissionResult.fromJson(Map<String, Object?> json) =>
      PermissionResult(
        status: json['status'] as String? ?? 'unrequested',
        asked: json['asked'] as bool? ?? false,
        detail: json['detail'] as String?,
      );

  final String status;
  final bool asked;
  final String? detail;

  bool get granted => status == 'granted';
}

class QrScanResult {
  const QrScanResult({this.text, this.cancelled = false});

  factory QrScanResult.fromJson(Map<String, Object?> json) => QrScanResult(
    text: json['text'] as String?,
    cancelled: json['cancelled'] as bool? ?? false,
  );

  final String? text;
  final bool cancelled;
}

class PickedFile {
  const PickedFile({
    required this.name,
    this.bytes,
    this.sha256 = '',
    this.spilledFile,
  });

  factory PickedFile.fromJson(Map<String, Object?> json) {
    final String? encoded = json['content'] as String?;
    return PickedFile(
      name: json['name'] as String? ?? '',
      bytes: encoded == null ? null : base64Decode(encoded),
      sha256: json['sha256'] as String? ?? '',
      spilledFile: json['spilledFile'] as String?,
    );
  }

  final String name;
  final Uint8List? bytes;
  final String sha256;
  final String? spilledFile;
}

class ClipboardCandidate {
  const ClipboardCandidate({this.text, this.likely = 'unknown'});

  factory ClipboardCandidate.fromJson(Map<String, Object?> json) =>
      ClipboardCandidate(
        text: json['text'] as String?,
        likely: json['likely'] as String? ?? 'unknown',
      );

  final String? text;
  final String likely;

  bool get hasCandidate => text != null && text!.isNotEmpty;
}

/// The facade. One instance per app; it is the only place that knows the wire
/// method names.
class HostBridge {
  HostBridge({
    required this.transport,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final HostTransport transport;
  final Duration timeout;
  final DateTime Function() _clock;

  int _sequence = 0;

  final CallbackSequence sequences = CallbackSequence();
  final StreamController<HostCallback> _events =
      StreamController<HostCallback>.broadcast();
  StreamSubscription<HostCallback>? _subscription;

  /// Events with gap detection already applied (`gap == true` means resync).
  Stream<({HostCallback callback, bool gap})> get events {
    _ensureSubscribed();
    return _events.stream.map(
      (HostCallback callback) =>
          (callback: callback, gap: sequences.accept(callback.seq)),
    );
  }

  void _ensureSubscribed() {
    if (_subscription != null) {
      return;
    }
    _subscription = transport.callbacks.listen((HostCallback callback) {
      if (!_events.isClosed) {
        _events.add(callback);
      }
    });
  }

  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    final String id = '${_clock().microsecondsSinceEpoch}-${_sequence++}';
    final HostRequest request = HostRequest(id: id, method: method, args: args);
    final HostResponse response;
    try {
      response = await transport.send(request).timeout(timeout);
    } on TimeoutException {
      throw const HostError(
        code: HostErrorCode.timeout,
        message: 'The host did not answer in time.',
        retryable: true,
      );
    }
    if (response.id != id) {
      throw HostError(
        code: HostErrorCode.internal,
        message: 'Response id ${response.id} does not match request $id.',
        retryable: false,
      );
    }
    return response.requireResult();
  }

  Future<HostCapabilities> capabilities() async =>
      HostCapabilities.fromJson(await invoke(BridgeMethod.hostCapabilities));

  Future<CoreCapabilities> coreCapabilities() async =>
      CoreCapabilities.fromJson(await invoke(BridgeMethod.coreCapabilities));

  Future<void> setup(SetupRequest request) async {
    await invoke(BridgeMethod.hostSetup, request.toArgs());
  }

  Future<void> shutdown() async {
    await invoke(BridgeMethod.hostShutdown);
    await dispose();
  }

  Future<StartAck> start({
    required int revision,
    required String mode,
    required String profileId,
    required String profileRevision,
    String configSource = 'profile',
  }) async {
    return StartAck.fromJson(
      await invoke(BridgeMethod.serviceStart, <String, Object?>{
        'revision': revision,
        'mode': mode,
        'configSource': configSource,
        'profileId': profileId,
        'profileRevision': profileRevision,
      }),
    );
  }

  Future<StartAck> stop({required int revision}) async {
    return StartAck.fromJson(
      await invoke(BridgeMethod.serviceStop, <String, Object?>{
        'revision': revision,
      }),
    );
  }

  Future<RuntimeStatus> status() async =>
      RuntimeStatus.fromJson(await invoke(BridgeMethod.serviceStatus));

  Future<ConfigCheckResult> checkConfig(
    Uint8List content, {
    String kind = 'singbox-json',
  }) async {
    return ConfigCheckResult.fromJson(
      await invoke(BridgeMethod.configCheck, <String, Object?>{
        'content': base64Encode(content),
        'kind': kind,
      }),
    );
  }

  Future<Uint8List> formatConfig(Uint8List content) async {
    final Map<String, Object?> json = await invoke(
      BridgeMethod.configFormat,
      <String, Object?>{'content': base64Encode(content)},
    );
    return base64Decode(json['content'] as String? ?? '');
  }

  Future<PreviewResult> preview(Uint8List content) async =>
      PreviewResult.fromJson(
        await invoke(BridgeMethod.configPreview, <String, Object?>{
          'content': base64Encode(content),
        }),
      );

  Future<List<ProfileMeta>> listProfiles() async {
    final Map<String, Object?> json = await invoke(BridgeMethod.profileList);
    return <ProfileMeta>[
      for (final Object? item
          in (json['items'] as List<Object?>?) ?? const <Object?>[])
        if (item is Map<Object?, Object?>)
          ProfileMeta.fromJson(item.cast<String, Object?>()),
    ];
  }

  Future<ProfileContent> readProfile(String id) async =>
      ProfileContent.fromJson(
        await invoke(BridgeMethod.profileRead, <String, Object?>{'id': id}),
      );

  Future<ProfileWriteResult> writeProfile({
    String? id,
    required String label,
    required Uint8List content,
    required String kind,
    String? expectedRevision,
    bool validate = true,
  }) async {
    return ProfileWriteResult.fromJson(
      await invoke(BridgeMethod.profileWrite, <String, Object?>{
        'id': id,
        'label': label,
        'kind': kind,
        'content': base64Encode(content),
        'expectedRevision': expectedRevision,
        'validate': validate,
      }),
    );
  }

  Future<void> deleteProfile(String id, {String? expectedRevision}) async {
    await invoke(BridgeMethod.profileDelete, <String, Object?>{
      'id': id,
      'expectedRevision': expectedRevision,
    });
  }

  /// Swaps the retained previous revision back in, atomically.
  Future<ProfileWriteResult> restoreProfile(String id, String revision) async {
    return ProfileWriteResult.fromJson(
      await invoke(BridgeMethod.profileRestore, <String, Object?>{
        'id': id,
        'revision': revision,
      }),
    );
  }

  Future<ApplyReport> applyProfile({
    required String id,
    required String revision,
    required String requestId,
    String mode = 'vpn',
  }) async {
    return ApplyReport.fromJson(
      await invoke(BridgeMethod.profileApply, <String, Object?>{
        'id': id,
        'revision': revision,
        'mode': mode,
        'requestId': requestId,
      }),
    );
  }

  Future<ProviderRefreshResult> refreshProviders(
    List<String> tags, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    return ProviderRefreshResult.fromJson(
      await invoke(BridgeMethod.providerRefresh, <String, Object?>{
        'tags': tags,
        'timeoutMillis': timeout.inMilliseconds,
      }),
    );
  }

  Future<bool> applySystemProxy({
    required bool enabled,
    required int port,
    List<String> bypass = const <String>[],
  }) async {
    final Map<String, Object?> json = await invoke(
      BridgeMethod.systemProxyApply,
      <String, Object?>{'enabled': enabled, 'port': port, 'bypass': bypass},
    );
    return json['applied'] as bool? ?? false;
  }

  Future<SystemProxyStatus> systemProxyStatus({int port = 0}) async =>
      SystemProxyStatus.fromJson(
        await invoke(BridgeMethod.systemProxyStatus, <String, Object?>{
          'port': port,
        }),
      );

  Future<PermissionResult> requestTunPermission() async =>
      PermissionResult.fromJson(
        await invoke(BridgeMethod.tunRequestPermission),
      );

  Future<QrScanResult> scanQr({
    String source = 'camera',
    String? imagePath,
  }) async {
    return QrScanResult.fromJson(
      await invoke(BridgeMethod.qrScan, <String, Object?>{
        'source': source,
        'imagePath': imagePath,
      }),
    );
  }

  Future<PickedFile?> pickConfig({
    List<String> accept = const <String>['json', 'yaml', 'bpf', 'txt'],
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final Map<String, Object?> json = await invoke(
      BridgeMethod.filePickConfig,
      <String, Object?>{'accept': accept, 'maxBytes': maxBytes},
    );
    if (json.isEmpty || json['name'] == null) {
      return null;
    }
    return PickedFile.fromJson(json);
  }

  Future<ClipboardCandidate> readClipboardCandidate() async =>
      ClipboardCandidate.fromJson(
        await invoke(BridgeMethod.clipboardReadCandidate),
      );

  Future<bool> setAutoLaunch(bool enabled) async {
    final Map<String, Object?> json = await invoke(
      BridgeMethod.appSetAutoLaunch,
      <String, Object?>{'enabled': enabled},
    );
    return json['enabled'] as bool? ?? false;
  }

  Future<bool> autoLaunchStatus() async {
    final Map<String, Object?> json = await invoke(
      BridgeMethod.appAutoLaunchStatus,
    );
    return json['enabled'] as bool? ?? false;
  }

  Future<void> updateTray({
    required bool running,
    required String mode,
    required int proxyPort,
    List<Map<String, Object?>> groups = const <Map<String, Object?>>[],
    bool showTitle = false,
    bool monochrome = true,
  }) async {
    await invoke(BridgeMethod.trayUpdate, <String, Object?>{
      'running': running,
      'mode': mode,
      'proxyPort': proxyPort,
      'groups': groups,
      'showTitle': showTitle,
      'monochrome': monochrome,
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _events.close();
    await transport.dispose();
  }
}
