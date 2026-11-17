import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

const String _validJson =
    '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],'
    '"route":{"final":"direct"}}';
const String _invalidJson =
    '{"outbounds":[{"type":"definitely-not-a-protocol"}]}';

/// The two host builds have two honest answers:
/// - default: core is absent, so config.* is `unsupportedPlatform`;
/// - linked: core is present, so a valid document is ok and an invalid one is
///   `coreRejectedConfig`.
/// Both run against a real child process on a loopback socket; no fake host.
void main() {
  final String? defaultExe = _findHost(preferLinked: false);
  final String? linkedExe = _findHost(preferLinked: true);

  test(
    'default host: core is absent and config.check is unsupported',
    () async {
      final String exe = defaultExe!;
      final _Host host = await _startHost(exe);
      addTearDown(host.stop);
      final HostBridge bridge = await host.connect();
      addTearDown(bridge.dispose);

      final HostCapabilities capabilities = await bridge.capabilities();
      expect(capabilities.core, isFalse);
      expect(capabilities.serviceModes, isNotEmpty);

      for (final String content in <String>[_validJson, _invalidJson]) {
        await expectLater(
          bridge.checkConfig(Uint8List.fromList(utf8.encode(content))),
          throwsA(
            isA<HostError>().having(
              (HostError error) => error.code,
              'code',
              HostErrorCode.unsupportedPlatform,
            ),
          ),
        );
      }

      final ProfileWriteResult written = await bridge.writeProfile(
        label: 'smoke-default',
        kind: 'singbox-json',
        content: Uint8List.fromList(utf8.encode(_validJson)),
        validate: false,
      );
      expect(
        (await bridge.listProfiles()).map((ProfileMeta p) => p.id),
        contains(written.id),
      );
      expect(
        utf8.decode((await bridge.readProfile(written.id)).content),
        _validJson,
      );
      expect((await bridge.status()).state, isNotEmpty);
    },
    skip: defaultExe == null ? 'core_host.exe not built' : false,
  );

  test('linked host: valid config is ok and invalid is rejected', () async {
    final String exe = linkedExe!;
    final _Host host = await _startHost(exe);
    addTearDown(host.stop);
    final HostBridge bridge = await host.connect();
    addTearDown(bridge.dispose);

    final HostCapabilities capabilities = await bridge.capabilities();
    expect(capabilities.core, isTrue);

    final ConfigCheckResult valid = await bridge.checkConfig(
      Uint8List.fromList(utf8.encode(_validJson)),
    );
    expect(valid.ok, isTrue);

    await expectLater(
      bridge.checkConfig(Uint8List.fromList(utf8.encode(_invalidJson))),
      throwsA(
        isA<HostError>().having(
          (HostError error) => error.code,
          'code',
          HostErrorCode.coreRejectedConfig,
        ),
      ),
    );
  }, skip: linkedExe == null ? 'core_host_libbox.exe not built' : false);
}

String? _findHost({required bool preferLinked}) {
  final String fromEnv = Platform.environment['JJBOX_SMOKE_EXE'] ?? '';
  if (fromEnv.isNotEmpty && File(fromEnv).existsSync()) return fromEnv;
  final String cwd = Directory.current.path;
  final List<String> names = preferLinked
      ? <String>['windows/core_host/core_host_libbox.exe']
      : <String>['windows/core_host/core_host.exe'];
  for (final String name in names) {
    final File file = File('$cwd/$name');
    if (file.existsSync()) return file.path;
  }
  return null;
}

class _Host {
  _Host(this.process, this.endpoint, this.tempDir);

  final Process process;
  final String endpoint;
  final Directory tempDir;

  Future<HostBridge> connect() async {
    final List<String> parts = endpoint.split(':');
    final SocketHostTransport transport = await SocketHostTransport.connect(
      parts[0],
      int.parse(parts[1]),
    );
    return HostBridge(transport: transport);
  }

  Future<void> stop() async {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on Object {
      // already gone
    }
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // best effort
    }
  }
}

Future<_Host> _startHost(String executable) async {
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'jjbox-host-smoke-',
  );
  final Process process = await Process.start(executable, <String>[
    '--pipe',
    '',
    '--listen',
    '127.0.0.1:0',
    '--data',
    tempDir.path,
  ]);
  final Completer<String> endpoint = Completer<String>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (String line) {
          const String prefix = 'LISTEN tcp:';
          if (line.startsWith(prefix) && !endpoint.isCompleted) {
            endpoint.complete(line.substring(prefix.length).trim());
          }
        },
        onDone: () {
          if (!endpoint.isCompleted) {
            endpoint.completeError(StateError('host exited before LISTEN'));
          }
        },
      );
  process.stderr.transform(utf8.decoder).listen((String _) {});
  final String address = await endpoint.future.timeout(
    const Duration(seconds: 8),
  );
  return _Host(process, address, tempDir);
}
