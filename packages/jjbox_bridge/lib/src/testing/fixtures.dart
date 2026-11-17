/// Redacted import fixtures for platform-conditional tests.
///
/// Every value here is synthetic: placeholder UUIDs, `example.com` hosts and no
/// credentials. Tests must never print a fixture that contains node passwords.
library;

import '../import_pipeline.dart';

class ImportFixture {
  const ImportFixture({
    required this.name,
    required this.text,
    this.source = ImportSource.file,
    this.expectedKind,
    this.expectError = false,
  });

  final String name;
  final String text;
  final ImportSource source;
  final ImportKind? expectedKind;
  final bool expectError;
}

const String kPlaceholderUuid = '11111111-2222-3333-4444-555555555555';

const String kShareLink = 'vless://$kPlaceholderUuid@example.com:443?security=tls#demo';
const String kShareLinkSecond = 'trojan://$kPlaceholderUuid@example.org:443#demo2';
const String kSubscriptionUrl = 'https://example.com/sub';
const String kClashYaml =
    'proxies:\n  - name: a\n    type: ss\n    server: example.com\n    port: 8388\n'
    'rules:\n  - MATCH,DIRECT\n';
const String kSip008 = '{"version":1,"servers":[{"server":"example.com","server_port":443}]}';
const String kSingboxJson =
    '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],'
    '"route":{"final":"direct"}}';
const String kSingboxWithEndpoint =
    '{"outbounds":[{"type":"direct","tag":"direct"}],'
    '"endpoints":[{"type":"wireguard","tag":"wg0","address":["10.0.0.2/32"]}]}';
const String kSip008Base64 = 'eyJ2ZXJzaW9uIjoxLCJzZXJ2ZXJzIjpbXX0=';

const List<ImportFixture> importFixtures = <ImportFixture>[
  ImportFixture(name: 'share-link', text: kShareLink, expectedKind: ImportKind.shareLink),
  ImportFixture(
    name: 'multi-link-crlf',
    text: '$kShareLink\r\n$kShareLinkSecond\r\n',
    expectedKind: ImportKind.shareLink,
  ),
  ImportFixture(
    name: 'subscription-url',
    text: kSubscriptionUrl,
    source: ImportSource.qr,
    expectedKind: ImportKind.subscriptionUrl,
  ),
  ImportFixture(name: 'clash-yaml', text: kClashYaml, expectedKind: ImportKind.clashYaml),
  ImportFixture(name: 'sip008', text: kSip008, expectedKind: ImportKind.sip008),
  ImportFixture(name: 'singbox-json', text: kSingboxJson, expectedKind: ImportKind.singboxJson),
  ImportFixture(
    name: 'singbox-with-endpoint',
    text: kSingboxWithEndpoint,
    expectedKind: ImportKind.singboxJson,
  ),
  ImportFixture(name: 'empty', text: '', expectError: true),
  ImportFixture(name: 'whitespace', text: '   \n\t ', expectError: true),
  ImportFixture(name: 'html-error-page', text: '<html><body>502 Bad Gateway</body></html>', expectError: true),
  ImportFixture(name: 'unknown-scheme', text: 'ftp://example.com/file', expectError: true),
  ImportFixture(name: 'plain-text', text: 'hello world', expectError: true),
  ImportFixture(
    name: 'qr-javascript',
    text: 'javascript:alert(1)',
    source: ImportSource.qr,
    expectError: true,
  ),
  ImportFixture(
    name: 'qr-data-url',
    text: 'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==',
    source: ImportSource.qr,
    expectError: true,
  ),
  ImportFixture(name: 'qr-control-char', text: 'vless://a\u0000b', source: ImportSource.qr, expectError: true),
];
