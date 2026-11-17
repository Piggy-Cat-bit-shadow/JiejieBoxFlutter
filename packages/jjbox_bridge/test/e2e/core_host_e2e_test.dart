import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jjbox_bridge/jjbox_bridge.dart';

/// End-to-end over the real Windows host process: Dart client -> socket -> Go
/// `core_host` -> profile store. No fake transport, no mock store.
///
/// Writes a trace (request order + timestamps) to `build/e2e/p3_e2e_trace.json`
/// so the P3 reports can cite the actual call sequence.
void main() {
  String findHost() {
    for (final String name in <String>[
      'core_host_libbox.exe',
      'core_host.exe',
    ]) {
      final File candidate = File('../../windows/core_host/$name').absolute;
      if (candidate.existsSync()) {
        return candidate.path;
      }
    }
    return '';
  }

  final String exe = findHost();
  final bool linked = exe.contains('core_host_libbox');
  final bool ready = Platform.isWindows && exe.isNotEmpty;
  final List<Map<String, Object?>> trace = <Map<String, Object?>>[];
  final List<HostCallback> events = <HostCallback>[];

  late Directory dataDir;
  Process? process;
  final List<Process> spawned = <Process>[];
  late SocketHostTransport transport;
  late HostBridge bridge;

  void record(String stream, String name, {bool? ok, Object? detail}) {
    trace.add(<String, Object?>{
      'at': DateTime.now().toIso8601String(),
      'stream': stream,
      'name': name,
      'ok': ?ok,
      'detail': ?detail?.toString(),
    });
  }

  Future<int> freePort() async {
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = probe.port;
    await probe.close();
    return port;
  }

  Future<({String host, int port})> startHost(
    String dir, {
    int port = 0,
  }) async {
    final Process started = await Process.start(exe, <String>[
      '--listen',
      '127.0.0.1:$port',
      '--data',
      dir,
      '--allow-test-hooks',
    ]);
    final Completer<({String host, int port})> completer =
        Completer<({String host, int port})>();
    started.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          if (line.startsWith('LISTEN ') && !completer.isCompleted) {
            final String address = line.substring(7).trim();
            final int split = address.lastIndexOf(':');
            completer.complete((
              host: address.substring(0, split),
              port: int.parse(address.substring(split + 1)),
            ));
          }
        });
    final ({String host, int port}) endpoint = await completer.future.timeout(
      const Duration(seconds: 10),
    );
    process = started;
    spawned.add(started);
    return endpoint;
  }

  Future<void> connect(({String host, int port}) endpoint) async {
    transport = await SocketHostTransport.connect(endpoint.host, endpoint.port);
    bridge = HostBridge(
      transport: transport,
      timeout: const Duration(seconds: 3),
    );
    bridge.events.listen((event) => events.add(event.callback));
  }

  setUpAll(() async {
    dataDir = await Directory.systemTemp.createTemp('jjbox-p3-e2e-');
  });

  tearDownAll(() async {
    try {
      await bridge.dispose();
    } catch (_) {}
    for (final Process started in spawned) {
      started.kill();
    }
    for (final Process started in spawned) {
      await started.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
    final Directory out = Directory('build/e2e');
    out.createSync(recursive: true);
    File('${out.path}/p3_e2e_trace.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'host': exe,
        'startedAt': trace.isEmpty ? null : trace.first['at'],
        'trace': trace,
        'events': <Map<String, Object?>>[
          for (final HostCallback event in events)
            <String, Object?>{
              'type': event.type,
              'seq': event.seq,
              'data': event.data,
            },
        ],
      }),
    );
  });

  test('the real host serves the whole bridge lifecycle', () async {
    final ({String host, int port}) endpoint = await startHost(dataDir.path);
    await connect(endpoint);
    record('host', 'LISTEN', detail: '${endpoint.host}:${endpoint.port}');

    final HostCapabilities capabilities = await bridge.capabilities();
    record('request', 'host.capabilities', ok: true);
    expect(capabilities.tun, isFalse);
    expect(capabilities.qrImageDecode, isFalse);
    expect(capabilities.core, linked);

    final Uint8List validConfig = Uint8List.fromList(
      utf8.encode(
        '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}',
      ),
    );
    if (linked) {
      final ConfigCheckResult valid = await bridge.checkConfig(validConfig);
      expect(valid.ok, isTrue);
      record('request', 'config.check(valid)', ok: true);
      await expectLater(
        bridge.checkConfig(
          Uint8List.fromList(
            utf8.encode('{"outbounds":[{"type":"definitely-not-a-protocol"}]}'),
          ),
        ),
        throwsA(
          isA<HostError>().having(
            (HostError error) => error.code,
            'code',
            HostErrorCode.coreRejectedConfig,
          ),
        ),
      );
      record(
        'request',
        'config.check(invalid)',
        ok: true,
        detail: 'core_rejected_config',
      );
    } else {
      await expectLater(
        bridge.checkConfig(validConfig),
        throwsA(
          isA<HostError>().having(
            (HostError error) => error.code,
            'code',
            HostErrorCode.unsupportedPlatform,
          ),
        ),
      );
      record(
        'request',
        'config.check(unlinked)',
        ok: true,
        detail: 'unsupported_platform',
      );
    }
    expect(capabilities.serviceModes, <String>['proxy']);

    final CoreCapabilities core = await bridge.coreCapabilities();
    record('request', 'core.capabilities', ok: true);
    expect(core.platform, 'windows');

    expect(await bridge.listProfiles(), isEmpty);
    record('request', 'profile.list', ok: true, detail: 'empty');

    final ProfileWriteResult v1 = await bridge.writeProfile(
      label: 'p3',
      kind: 'local',
      content: Uint8List.fromList(utf8.encode('{"v":1}')),
    );
    record('request', 'profile.write(v1)', ok: true, detail: v1.revision);
    expect(v1.revision, isNotEmpty);

    final ProfileWriteResult v2 = await bridge.writeProfile(
      id: v1.id,
      label: 'p3',
      kind: 'local',
      content: Uint8List.fromList(utf8.encode('{"v":2}')),
      expectedRevision: v1.revision,
    );
    record('request', 'profile.write(v2)', ok: true, detail: v2.revision);

    final ProfileWriteResult restored = await bridge.restoreProfile(
      v1.id,
      v1.revision,
    );
    record(
      'request',
      'profile.restore(v1)',
      ok: true,
      detail: restored.revision,
    );
    expect(restored.revision, v1.revision);
    expect(utf8.decode((await bridge.readProfile(v1.id)).content), '{"v":1}');

    final StartAck ack = await bridge.start(
      revision: 1,
      mode: 'proxy',
      profileId: v1.id,
      profileRevision: v1.revision,
    );
    record('request', 'service.start', ok: ack.accepted);
    expect(ack.accepted, isTrue);
    expect((await bridge.status()).state, isNot('running'));

    await bridge.invoke('test.runtime', <String, Object?>{'running': true});
    record('request', 'test.runtime(running)', ok: true);
    final RuntimeStatus running = await bridge.status();
    expect(running.state, 'running');

    await bridge.stop(revision: 2);
    await bridge.invoke('test.runtime', <String, Object?>{'running': false});
    record('request', 'service.stop', ok: true);
    expect((await bridge.status()).state, 'idle');

    await bridge.start(
      revision: 3,
      mode: 'vpn',
      profileId: v1.id,
      profileRevision: v1.revision,
    );
    expect((await bridge.status()).state, 'awaitingPermission');
    await bridge.invoke('test.permission', <String, Object?>{'granted': true});
    record('request', 'test.permission(granted)', ok: true);
    expect((await bridge.status()).state, 'starting');
    await bridge.invoke('test.runtime', <String, Object?>{'running': true});
    expect((await bridge.status()).state, 'running');
    await bridge.stop(revision: 4);
    await bridge.invoke('test.runtime', <String, Object?>{'running': false});

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      events.where((HostCallback e) => e.type == 'service.state'),
      isNotEmpty,
    );
    expect(
      events.where((HostCallback e) => e.type == 'permission.changed'),
      isNotEmpty,
    );
    for (final HostCallback event in events) {
      record('event', event.type, detail: 'seq=${event.seq}');
    }

    await bridge.shutdown();
    record('request', 'host.shutdown', ok: true);
  }, skip: !ready);

  test('the client reconnects to a restarted host on the same port', () async {
    if (!ready) {
      return;
    }
    final int port = await freePort();
    final Directory dir = await Directory.systemTemp.createTemp(
      'jjbox-p3-reconnect-',
    );
    addTearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    final ({String host, int port}) endpoint = await startHost(
      dir.path,
      port: port,
    );
    await connect(endpoint);
    final ProfileWriteResult marker = await bridge.writeProfile(
      label: 'reconnect',
      kind: 'local',
      content: Uint8List.fromList(utf8.encode('{"marker":true}')),
    );
    record(
      'request',
      'profile.write(reconnect marker)',
      ok: true,
      detail: marker.revision,
    );

    process?.kill();
    await process?.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // The first call after an abrupt kill may see a buffered write and then time
    // out; both answers mean "state unknown", which is what the contract says.
    try {
      await bridge.status();
      record(
        'client',
        'status-after-kill',
        ok: false,
        detail: 'unexpected success',
      );
    } on HostError catch (error) {
      expect(
        error.code,
        anyOf(HostErrorCode.transportDisconnected, HostErrorCode.timeout),
      );
      record(
        'client',
        'status-after-kill',
        ok: true,
        detail: error.code.wireName,
      );
    }

    final ({String host, int port}) restarted = await startHost(
      dir.path,
      port: port,
    );
    expect(restarted.port, port);
    await transport.reconnect();
    record('client', 'reconnect', ok: true, detail: 'same port $port');
    final List<ProfileMeta> profiles = await bridge.listProfiles();
    expect(profiles.single.id, marker.id);
    expect(
      utf8.decode((await bridge.readProfile(marker.id)).content),
      '{"marker":true}',
    );
    await bridge.shutdown();
  }, skip: !ready);

  test('profiles survive a host restart', () async {
    if (!ready) {
      return;
    }
    process?.kill();
    await process?.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    await bridge.dispose();

    final ({String host, int port}) endpoint = await startHost(dataDir.path);
    await connect(endpoint);
    final List<ProfileMeta> profiles = await bridge.listProfiles();
    record(
      'request',
      'profile.list(after restart)',
      ok: true,
      detail: '${profiles.length}',
    );
    expect(profiles, hasLength(1));
    expect(
      utf8.decode((await bridge.readProfile(profiles.single.id)).content),
      '{"v":1}',
    );
    await bridge.shutdown();
  }, skip: !ready);
}
