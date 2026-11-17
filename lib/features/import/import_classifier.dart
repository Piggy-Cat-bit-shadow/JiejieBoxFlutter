import 'dart:convert';

import 'package:yaml/yaml.dart';

/// What an import text is, decided by the UI before any kernel call.
///
/// This is intentionally **not** a config validator: the kernel's
/// `CheckConfig`/`AnalyzeConfig` (CONTRACTS K1/K2) remain the authority. The
/// classifier only answers "is this one complete config, a node list, a
/// subscription URL, or unusable", because the import UI must choose a
/// different target for each.
enum ImportFormat {
  empty,
  singBoxJson,
  clashYaml,
  sip008,
  shareLinks,
  base64Links,
  subscriptionUrl,
  html,
  unsupported,
}

class ImportIssue {
  const ImportIssue(this.line, this.message);

  final int line;
  final String message;

  @override
  String toString() => 'line $line: $message';
}

class ImportPreview {
  const ImportPreview({
    required this.format,
    required this.text,
    this.nodeCount = 0,
    this.skipped = 0,
    this.issues = const [],
    this.hints = const [],
  });

  final ImportFormat format;

  /// The text the UI should keep: base64 payloads are unwrapped.
  final String text;
  final int nodeCount;
  final int skipped;
  final List<ImportIssue> issues;
  final List<String> hints;

  bool get isCompleteConfig =>
      format == ImportFormat.singBoxJson ||
      format == ImportFormat.clashYaml ||
      format == ImportFormat.sip008;

  /// Whether the import can produce a profile or append nodes.
  bool get isUsable => isCompleteConfig || nodeCount > 0;

  String get formatLabel => switch (format) {
    ImportFormat.empty => 'Empty',
    ImportFormat.singBoxJson => 'sing-box JSON',
    ImportFormat.clashYaml => 'Clash YAML',
    ImportFormat.sip008 => 'SIP008',
    ImportFormat.shareLinks => 'Share links',
    ImportFormat.base64Links => 'Base64 links',
    ImportFormat.subscriptionUrl => 'Subscription URL',
    ImportFormat.html => 'HTML page',
    ImportFormat.unsupported => 'Unsupported',
  };
}

const _shareSchemes = {
  'ss',
  'vmess',
  'vless',
  'trojan',
  'tuic',
  'hysteria',
  'hy2',
  'hysteria2',
  'anytls',
};

const _builtinOutbounds = {'direct', 'block', 'dns'};

const _base64Pattern = r'^[A-Za-z0-9+/]+={0,2}$';

ImportPreview classifyImport(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const ImportPreview(
      format: ImportFormat.empty,
      text: '',
      hints: ['Nothing to import'],
    );
  }
  final lower = text.toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      (text.startsWith('<') && lower.contains('<body'))) {
    return ImportPreview(
      format: ImportFormat.html,
      text: text,
      hints: const ['This looks like a web page, not a config or node list'],
    );
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    final json = _classifyJson(text);
    if (json != null) {
      return json;
    }
  }
  final yaml = _classifyYaml(text);
  if (yaml != null) {
    return yaml;
  }
  final base64 = _classifyBase64(text);
  if (base64 != null) {
    return base64;
  }
  if (!text.contains('\n') && RegExp(r'^https?://\S+$').hasMatch(text)) {
    return ImportPreview(
      format: ImportFormat.subscriptionUrl,
      text: text,
      hints: const [
        'Remote subscription needs the network + parser bridge; not fetched here',
      ],
    );
  }
  final links = _classifyLinks(text);
  if (links != null) {
    return links;
  }
  return const ImportPreview(
    format: ImportFormat.unsupported,
    text: '',
    hints: ['Unrecognized format'],
  );
}

ImportPreview? _classifyJson(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) {
    return ImportPreview(
      format: ImportFormat.unsupported,
      text: text,
      hints: const ['JSON is not an object'],
    );
  }
  final outbounds = decoded['outbounds'];
  if (outbounds is List) {
    var nodes = 0;
    final issues = <ImportIssue>[];
    final tags = <String>{};
    for (final (index, item) in outbounds.indexed) {
      if (item is! Map) {
        issues.add(ImportIssue(index + 1, 'outbound is not an object'));
        continue;
      }
      final type = item['type'];
      final tag = item['tag'];
      if (tag is String && tag.isNotEmpty && !tags.add(tag)) {
        issues.add(ImportIssue(index + 1, 'duplicate tag: $tag'));
      }
      if (type is String && _builtinOutbounds.contains(type)) {
        continue;
      }
      nodes++;
    }
    return ImportPreview(
      format: ImportFormat.singBoxJson,
      text: text,
      nodeCount: nodes,
      skipped: issues.length,
      issues: issues,
      hints: [if (nodes == 0) 'No proxy outbound found'],
    );
  }
  final servers = decoded['servers'];
  if (servers is List) {
    return ImportPreview(
      format: ImportFormat.sip008,
      text: text,
      nodeCount: servers.length,
      hints: const ['SIP008 server list'],
    );
  }
  final proxies = decoded['proxies'];
  if (proxies is List) {
    return ImportPreview(
      format: ImportFormat.clashYaml,
      text: text,
      nodeCount: proxies.length,
      hints: const ['Clash proxy list in JSON'],
    );
  }
  return const ImportPreview(
    format: ImportFormat.unsupported,
    text: '',
    hints: ['JSON object without outbounds/servers/proxies'],
  );
}

ImportPreview? _classifyYaml(String text) {
  if (!text.contains('proxies:') &&
      !text.contains('proxy-groups:') &&
      !text.contains('rules:')) {
    return null;
  }
  dynamic doc;
  try {
    doc = loadYaml(text);
  } catch (error) {
    return ImportPreview(
      format: ImportFormat.unsupported,
      text: text,
      hints: ['Clash YAML could not be parsed: $error'],
    );
  }
  if (doc is! Map) {
    return const ImportPreview(
      format: ImportFormat.unsupported,
      text: '',
      hints: ['YAML is not a mapping'],
    );
  }
  final proxies = doc['proxies'];
  final groups = doc['proxy-groups'];
  var nodes = 0;
  final names = <String>{};
  final issues = <ImportIssue>[];
  if (proxies is YamlList) {
    for (final (index, item) in proxies.indexed) {
      if (item is Map && item['name'] != null) {
        final name = '${item['name']}';
        if (!names.add(name)) {
          issues.add(ImportIssue(index + 1, 'duplicate name: $name'));
        }
        nodes++;
      } else {
        issues.add(ImportIssue(index + 1, 'proxy without name'));
      }
    }
  }
  return ImportPreview(
    format: ImportFormat.clashYaml,
    text: text,
    nodeCount: nodes,
    skipped: issues.length,
    issues: issues,
    hints: [
      if (groups is YamlList) '${groups.length} proxy groups found',
      'Clash YAML must be converted to sing-box before use',
    ],
  );
}

ImportPreview? _classifyBase64(String text) {
  final compact = text.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 16 ||
      compact.length % 4 != 0 ||
      !RegExp(_base64Pattern).hasMatch(compact)) {
    return null;
  }
  String decoded;
  try {
    decoded = utf8.decode(base64Decode(compact));
  } catch (_) {
    return null;
  }
  if (!decoded.contains('://')) {
    return null;
  }
  final inner = classifyImport(decoded);
  return ImportPreview(
    format: ImportFormat.base64Links,
    text: decoded,
    nodeCount: inner.nodeCount,
    skipped: inner.skipped,
    issues: inner.issues,
    hints: ['Base64 decoded · ${inner.formatLabel}', ...inner.hints],
  );
}

ImportPreview? _classifyLinks(String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  final seen = <String>{};
  var nodes = 0;
  var skipped = 0;
  final issues = <ImportIssue>[];
  for (final (index, raw) in lines.indexed) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(line);
    if (scheme == null) {
      skipped++;
      issues.add(ImportIssue(index + 1, 'not a link'));
      continue;
    }
    final name = scheme.group(1)!.toLowerCase();
    if (!_shareSchemes.contains(name)) {
      skipped++;
      issues.add(ImportIssue(index + 1, 'unsupported scheme: $name'));
      continue;
    }
    if (!seen.add(line)) {
      skipped++;
      issues.add(ImportIssue(index + 1, 'duplicate link'));
      continue;
    }
    nodes++;
  }
  if (nodes == 0) {
    return null;
  }
  return ImportPreview(
    format: ImportFormat.shareLinks,
    text: text,
    nodeCount: nodes,
    skipped: skipped,
    issues: issues,
    hints: [
      if (skipped > 0) '$skipped line(s) skipped',
      'Node links are parsed by the kernel bridge before saving',
    ],
  );
}
