import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/features/import/import_classifier.dart';
import 'package:jiejiebox_flutter/state/app_state.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

void main() {
  group('classifyImport', () {
    test('empty text', () {
      expect(classifyImport('  \n ').format, ImportFormat.empty);
    });

    test('html error page is not a config', () {
      final preview = classifyImport(
        '<!DOCTYPE html><html><body>502</body></html>',
      );
      expect(preview.format, ImportFormat.html);
      expect(preview.isUsable, isFalse);
    });

    test('sing-box JSON counts proxy outbounds only', () {
      const text = '''
{"outbounds":[
  {"type":"selector","tag":"proxy","outbounds":["a","b"]},
  {"type":"vless","tag":"a"},
  {"type":"vmess","tag":"b"},
  {"type":"direct","tag":"direct"},
  {"type":"block","tag":"block"}
]}''';
      final preview = classifyImport(text);
      expect(preview.format, ImportFormat.singBoxJson);
      expect(preview.nodeCount, 3);
      expect(preview.isCompleteConfig, isTrue);
    });

    test('sing-box JSON duplicate tags are reported', () {
      const text =
          '{"outbounds":[{"type":"vless","tag":"a"},{"type":"vmess","tag":"a"}]}';
      final preview = classifyImport(text);
      expect(preview.nodeCount, 2);
      expect(
        preview.issues.map((issue) => issue.message),
        contains('duplicate tag: a'),
      );
    });

    test('json without outbounds/servers/proxies is unsupported', () {
      expect(classifyImport('{"foo":1}').isUsable, isFalse);
    });

    test('clash yaml counts proxies and flags duplicates', () {
      const text = '''
proxies:
  - {name: a, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: x}
  - {name: a, type: ss, server: 127.0.0.1, port: 2, cipher: aes-128-gcm, password: x}
proxy-groups:
  - {name: g, type: select, proxies: [a]}
rules:
  - MATCH,DIRECT
''';
      final preview = classifyImport(text);
      expect(preview.format, ImportFormat.clashYaml);
      expect(preview.nodeCount, 2);
      expect(preview.skipped, 1);
    });

    test('sip008 servers', () {
      const text = '{"version":1,"servers":[{"server":"a"},{"server":"b"}]}';
      final preview = classifyImport(text);
      expect(preview.format, ImportFormat.sip008);
      expect(preview.nodeCount, 2);
    });

    test('base64 share links are unwrapped', () {
      const links =
          'ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#a\n'
          'vless://uuid@example.com:443#b';
      final encoded = base64Encode(utf8.encode(links));
      final preview = classifyImport(encoded);
      expect(preview.format, ImportFormat.base64Links);
      expect(preview.nodeCount, 2);
      expect(preview.text, links);
    });

    test('share links with CRLF, unknown scheme and duplicates', () {
      const text =
          'ss://a@1.1.1.1:1#one\r\n'
          'unknown://x\r\n'
          'ss://a@1.1.1.1:1#one\r\n'
          'trojan://p@example.com:443#t\r\n';
      final preview = classifyImport(text);
      expect(preview.format, ImportFormat.shareLinks);
      expect(preview.nodeCount, 2);
      expect(preview.skipped, 2);
      expect(
        preview.issues.map((issue) => issue.message),
        containsAll(['unsupported scheme: unknown', 'duplicate link']),
      );
    });

    test('single http url is a subscription, not a share link', () {
      final preview = classifyImport('https://example.com/sub?token=abc');
      expect(preview.format, ImportFormat.subscriptionUrl);
      expect(preview.isUsable, isTrue);
    });

    test('plain text is unsupported', () {
      expect(classifyImport('hello world').format, ImportFormat.unsupported);
    });

    test('malformed yaml does not crash', () {
      final preview = classifyImport('proxies:\n  - [unclosed');
      expect(preview.isUsable, isFalse);
    });
  });

  group('composeImportedConfig', () {
    test('assembles parsed nodes with an inbound and route', () {
      final preview = PreviewResult(
        ok: true,
        format: 'links',
        items: <PreviewItem>[
          PreviewItem(
            tag: 'node-a',
            type: 'shadowsocks',
            endpoint: false,
            content: jsonEncode(<String, Object?>{
              'type': 'shadowsocks',
              'tag': 'node-a',
              'server': '127.0.0.1',
              'server_port': 8388,
              'method': 'aes-128-gcm',
              'password': 'pass',
            }),
          ),
        ],
      );
      final config =
          jsonDecode(composeImportedConfig(preview, listenPort: 0)!)
              as Map<String, Object?>;
      final outbounds = config['outbounds'] as List<Object?>;
      expect(outbounds.length, 2);
      expect((config['inbounds'] as List<Object?>).length, 1);
      expect((config['route'] as Map<String, Object?>)['final'], 'node-a');
    });

    test('returns null without node content', () {
      const preview = PreviewResult(ok: true);
      expect(composeImportedConfig(preview), isNull);
    });
  });
}
