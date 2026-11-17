/// Import pipeline: classify -> preview with the core -> confirm -> atomic write.
///
/// The classification below is a *routing* heuristic only. It decides which core
/// entry point to ask (`config.preview` for "what format is this?", `config.check`
/// for "is this exact sing-box document valid?"); it never parses nodes, links or
/// YAML, because the five hosts must not grow five parsers (contract `import_model`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'host_bridge.dart';
import 'profile_transaction.dart';
import 'sha256.dart';

enum ImportSource { file, clipboard, qr, deepLink, url }

enum ImportKind {
  shareLink,
  subscriptionUrl,
  base64Bundle,
  clashYaml,
  sip008,
  singboxJson,
  unknown,
}

/// One payload offered to the UI, before confirmation.
class ImportRequest {
  const ImportRequest({
    required this.source,
    this.bytes,
    this.text,
    this.label,
  });

  final ImportSource source;
  final Uint8List? bytes;
  final String? text;
  final String? label;
}

/// A prepared plan: what was found, and the exact bytes that would be stored.
class ImportPlan {
  const ImportPlan({
    required this.source,
    required this.kind,
    required this.bytes,
    required this.sha256,
    required this.label,
    this.preview,
    this.check,
  });

  final ImportSource source;
  final ImportKind kind;
  final Uint8List bytes;
  final String sha256;
  final String label;
  final PreviewResult? preview;
  final ConfigCheckResult? check;

  int get itemCount => preview?.count ?? (check?.ok == true ? 1 : 0);

  bool get needsConfirm => true;
}

class ImportResult {
  const ImportResult({
    required this.plan,
    required this.profile,
    required this.deduplicated,
  });

  final ImportPlan plan;
  final ProfileWriteResult profile;
  final bool deduplicated;
}

class ImportException implements Exception {
  const ImportException(this.error);

  ImportException.code(
    HostErrorCode code,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
  }) : this(HostError(
          code: code,
          message: message,
          retryable: code.retryable,
          details: details,
        ));

  final HostError error;

  HostErrorCode get code => error.code;

  @override
  String toString() => 'ImportException(${error.code.wireName}: ${error.message})';
}

const Set<String> _shareSchemes = <String>{
  'ss',
  'ssr',
  'vmess',
  'vless',
  'trojan',
  'tuic',
  'hysteria',
  'hysteria2',
  'hy2',
  'anytls',
  'socks',
  'socks5',
  'snell',
  'wireguard',
};

class ImportPipeline {
  ImportPipeline({
    required this.bridge,
    required this.repository,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxQrChars = 4096,
    this.maxClipboardChars = 1024 * 1024,
  });

  final HostBridge bridge;
  final ProfileRepository repository;
  final int maxBytes;
  final int maxQrChars;
  final int maxClipboardChars;

  final Map<String, String> _byDigest = <String, String>{};

  /// Classifies a payload without parsing it. Kept public for tests and fixtures.
  static ImportKind classify(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return ImportKind.unknown;
    }
    if (trimmed.startsWith('<')) {
      return ImportKind.unknown;
    }
    if (trimmed.startsWith('{')) {
      if (trimmed.contains('"outbounds"') || trimmed.contains('"route"')) {
        return ImportKind.singboxJson;
      }
      if (trimmed.contains('"servers"') && trimmed.contains('"version"')) {
        return ImportKind.sip008;
      }
      return ImportKind.unknown;
    }
    final List<String> lines = trimmed
        .split(RegExp(r'\r?\n'))
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);
    final bool yamlish = lines.any((String line) =>
        line.startsWith('proxies:') ||
        line.startsWith('proxy-groups:') ||
        line.startsWith('proxy-providers:') ||
        line.startsWith('rules:'));
    if (yamlish) {
      return ImportKind.clashYaml;
    }
    final String first = lines.first;
    final Uri? uri = Uri.tryParse(first);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return lines.length == 1 ? ImportKind.subscriptionUrl : ImportKind.shareLink;
    }
    if (uri != null && _shareSchemes.contains(uri.scheme)) {
      return ImportKind.shareLink;
    }
    if (_looksBase64(trimmed)) {
      try {
        final String decoded = utf8.decode(base64.decode(trimmed));
        if (decoded.contains('://')) {
          return ImportKind.base64Bundle;
        }
      } on FormatException {
        return ImportKind.unknown;
      }
    }
    return ImportKind.unknown;
  }

  Future<ImportPlan> prepare(ImportRequest request) async {
    final Uint8List bytes = request.bytes ??
        Uint8List.fromList(utf8.encode(request.text ?? ''));
    if (bytes.isEmpty) {
      throw ImportException.code(HostErrorCode.invalidArgument, 'the input is empty');
    }
    if (bytes.length > maxBytes) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the input is larger than ${maxBytes ~/ 1024} KiB',
      );
    }
    final String text = request.text ?? utf8.decode(bytes, allowMalformed: true);
    if (request.source == ImportSource.qr) {
      _validateQrText(text);
    }
    if (request.source == ImportSource.clipboard && text.length > maxClipboardChars) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the clipboard payload is too large',
      );
    }
    final ImportKind kind = classify(text);
    if (kind == ImportKind.unknown) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the input is not a share link, a subscription URL or a supported config',
        details: <String, Object?>{'source': request.source.name},
      );
    }
    final String digest = sha256Hex(bytes);
    final String label = request.label?.trim().isNotEmpty == true
        ? request.label!.trim()
        : _labelFor(kind, request.source);

    if (kind == ImportKind.singboxJson) {
      final ConfigCheckResult check = await _call(
        () => bridge.checkConfig(bytes),
      );
      if (!check.ok) {
        throw ImportException.code(
          HostErrorCode.coreRejectedConfig,
          check.message ?? 'the core rejected the document',
          details: <String, Object?>{'coreCode': check.code},
        );
      }
      return ImportPlan(
        source: request.source,
        kind: kind,
        bytes: bytes,
        sha256: digest,
        label: label,
        check: check,
      );
    }

    final PreviewResult preview = await _call(() => bridge.preview(bytes));
    if (!preview.ok) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        preview.message ?? 'the core could not read the document',
        details: <String, Object?>{'coreCode': preview.code},
      );
    }
    return ImportPlan(
      source: request.source,
      kind: kind,
      bytes: bytes,
      sha256: digest,
      label: label,
      preview: preview,
    );
  }

  /// Writes the plan only after an explicit confirmation.
  ///
  /// Importing the same bytes twice returns the existing profile; it never creates
  /// a second copy and never rewrites the first one.
  Future<ImportResult> commit(
    ImportPlan plan, {
    required bool confirmed,
    String kind = 'local',
    String? expectedRevision,
  }) async {
    if (!confirmed) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'importing requires an explicit confirmation',
      );
    }
    final String? existing = _byDigest[plan.sha256];
    if (existing != null) {
      final List<ProfileMeta> profiles = await repository.list();
      ProfileMeta? match;
      for (final ProfileMeta meta in profiles) {
        if (meta.id == existing) {
          match = meta;
          break;
        }
      }
      if (match != null) {
        return ImportResult(
          plan: plan,
          profile: ProfileWriteResult(
            id: match.id,
            revision: match.revision,
            validated: true,
            bytes: match.bytes,
          ),
          deduplicated: true,
        );
      }
      _byDigest.remove(plan.sha256);
    }
    final ProfileWriteResult written = await repository.write(
      label: plan.label,
      kind: kind,
      content: plan.bytes,
      expectedRevision: expectedRevision,
      validate: true,
    );
    _byDigest[plan.sha256] = written.id;
    return ImportResult(plan: plan, profile: written, deduplicated: false);
  }

  /// Maps a transport/core failure onto the import vocabulary instead of leaking
  /// a bare HostError: callers of the pipeline only need to handle ImportException.
  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on HostError catch (error) {
      throw ImportException(error);
    }
  }

  /// Forgets the dedupe cache (a new user action should not be silently swallowed).
  void resetDedupe() => _byDigest.clear();

  void _validateQrText(String text) {
    if (text.trim().isEmpty) {
      throw ImportException.code(HostErrorCode.invalidArgument, 'the QR code is empty');
    }
    if (text.length > maxQrChars) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the QR payload is longer than $maxQrChars characters',
      );
    }
    if (text.contains(RegExp(r'[\u0000-\u001f]'))) {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the QR payload contains control characters',
      );
    }
    final Uri? uri = Uri.tryParse(text.trim());
    if (uri == null) {
      throw ImportException.code(HostErrorCode.invalidArgument, 'the QR payload is not a URI');
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme == 'javascript' || scheme == 'data' || scheme == 'file') {
      throw ImportException.code(
        HostErrorCode.invalidArgument,
        'the QR scheme "$scheme" is not allowed',
      );
    }
  }

  static bool _looksBase64(String text) {
    if (text.length < 8 || text.length % 4 != 0) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9+/=\r\n]+$').hasMatch(text);
  }

  static String _labelFor(ImportKind kind, ImportSource source) {
    final String suffix = switch (kind) {
      ImportKind.shareLink => 'links',
      ImportKind.subscriptionUrl => 'subscription',
      ImportKind.base64Bundle => 'links',
      ImportKind.clashYaml => 'clash',
      ImportKind.sip008 => 'sip008',
      ImportKind.singboxJson => 'config',
      ImportKind.unknown => 'import',
    };
    return '${source.name}-$suffix';
  }
}
