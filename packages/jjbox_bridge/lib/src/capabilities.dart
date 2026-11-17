/// What the host can actually do, as answered by `host.capabilities`.
///
/// Dart branches on these booleans instead of `Platform.is*`; a missing
/// capability is a first-class answer, not a failed call.
library;

class HostCapabilities {
  const HostCapabilities({
    this.tun = false,
    this.systemProxy = false,
    this.perAppProxy = false,
    this.autostart = false,
    this.tray = false,
    this.qrCamera = false,
    this.qrImageDecode = false,
    this.fileImport = false,
    this.clipboardWatch = false,
    this.notifications = false,
    this.deepLink = false,
    this.memoryPressure = false,
    this.serviceModes = const <String>['vpn'],
  });

  factory HostCapabilities.fromJson(Map<String, Object?> json) {
    bool flag(String key) => json[key] as bool? ?? false;
    final List<Object?> modes =
        (json['serviceModes'] as List<Object?>?) ?? const <Object?>['vpn'];
    return HostCapabilities(
      tun: flag('tun'),
      systemProxy: flag('systemProxy'),
      perAppProxy: flag('perAppProxy'),
      autostart: flag('autostart'),
      tray: flag('tray'),
      qrCamera: flag('qrCamera'),
      qrImageDecode: flag('qrImageDecode'),
      fileImport: flag('fileImport'),
      clipboardWatch: flag('clipboardWatch'),
      notifications: flag('notifications'),
      deepLink: flag('deepLink'),
      memoryPressure: flag('memoryPressure'),
      serviceModes: modes.whereType<String>().toList(growable: false),
    );
  }

  final bool tun;
  final bool systemProxy;
  final bool perAppProxy;
  final bool autostart;
  final bool tray;
  final bool qrCamera;
  final bool qrImageDecode;
  final bool fileImport;
  final bool clipboardWatch;
  final bool notifications;
  final bool deepLink;
  final bool memoryPressure;
  final List<String> serviceModes;

  bool get supportsTun => tun;

  bool get supportsDesktopShell => tray || autostart;

  Map<String, Object?> toJson() => <String, Object?>{
    'tun': tun,
    'systemProxy': systemProxy,
    'perAppProxy': perAppProxy,
    'autostart': autostart,
    'tray': tray,
    'qrCamera': qrCamera,
    'qrImageDecode': qrImageDecode,
    'fileImport': fileImport,
    'clipboardWatch': clipboardWatch,
    'notifications': notifications,
    'deepLink': deepLink,
    'memoryPressure': memoryPressure,
    'serviceModes': serviceModes,
  };
}

/// `core.capabilities`: the probe B requires before any optional call.
///
/// `types` is what this build's registries *know*, not what it can run: a QUIC
/// protocol needs [buildQuic] as well, and anything else is proven by
/// constructing a single-node config through `config.check`.
class CoreCapabilities {
  const CoreCapabilities({
    required this.apiVersion,
    this.buildId,
    this.buildQuic,
    this.platform = '',
    this.version,
    this.goVersion,
    this.types = const <String>[],
  });

  factory CoreCapabilities.fromJson(Map<String, Object?> json) {
    final List<Object?> rawTypes =
        (json['capabilities'] as List<Object?>?) ??
        (json['types'] as List<Object?>?) ??
        const <Object?>[];
    final List<String> types = <String>[];
    for (final Object? entry in rawTypes) {
      if (entry is String) {
        types.add(entry);
      } else if (entry is Map<Object?, Object?>) {
        final Object? values = entry['types'];
        if (values is List<Object?>) {
          types.addAll(values.whereType<String>());
        }
      }
    }
    return CoreCapabilities(
      apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
      buildId: json['buildId'] as String?,
      buildQuic: json['buildQuic'] as bool?,
      platform: json['platform'] as String? ?? '',
      version: json['version'] as String?,
      goVersion: json['goVersion'] as String?,
      types: types,
    );
  }

  final int apiVersion;
  final String? buildId;
  final bool? buildQuic;
  final String platform;
  final String? version;
  final String? goVersion;
  final List<String> types;

  /// The only sound local test for "this build can run the protocol".
  bool canRunProtocol(String type) {
    if (!types.contains(type)) {
      return false;
    }
    const Set<String> quicFamily = <String>{'hysteria', 'hysteria2', 'tuic'};
    if (quicFamily.contains(type)) {
      return buildQuic ?? false;
    }
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'apiVersion': apiVersion,
    'buildId': buildId,
    'buildQuic': buildQuic,
    'platform': platform,
    'version': version,
    'goVersion': goVersion,
    'capabilities': <Object?>[
      for (final String type in types)
        <String, Object?>{
          'kind': 'outbound',
          'types': <String>[type],
        },
    ],
  };
}
