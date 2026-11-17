import 'dart:convert';
import 'dart:io';

import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_runtime.dart';

/// Debug-only end-to-end probe used by the Windows build verifier.
///
/// It runs in the real Flutter app process, so it exercises the C++ plugin, the
/// named pipe and the app-owned host supervisor together - not a fake transport.
/// The product path is unchanged; `main` enters this only when
/// `JJBOX_SMOKE=1` in a debug build.
Future<void> runHostSmoke() async {
  final String outPath = Platform.environment['JJBOX_SMOKE_OUT'] ?? '';
  final File output = File(
    outPath.isEmpty
        ? '${Directory.systemTemp.path}\\jjbox_app_smoke.json'
        : outPath,
  );
  final Map<String, Object?> result = <String, Object?>{'ok': false};
  CoreRuntime? runtime;
  try {
    runtime = await createCoreRuntime(
      probeTimeout: const Duration(seconds: 10),
    );
    result['real'] = runtime.isReal;
    final jb.HostBridge? host = runtime.host;
    if (host == null) {
      result['error'] = 'host bridge is unavailable';
    } else {
      final jb.HostCapabilities caps = await host.capabilities();
      result['capabilities'] = <String, Object?>{
        'core': caps.core,
        'tun': caps.tun,
        'serviceModes': caps.serviceModes,
        'events': false,
      };
      const String config =
          '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}';
      final jb.ProfileWriteResult profile = await host.writeProfile(
        label: 'app-smoke',
        kind: 'local',
        content: utf8.encode(config),
      );
      result['profileId'] = profile.id;
      final jb.StartAck ack = await host.start(
        revision: 1,
        mode: 'proxy',
        profileId: profile.id,
        profileRevision: profile.revision,
      );
      result['accepted'] = ack.accepted;
      final jb.RuntimeStatus running = await host.status();
      result['runningState'] = running.state;
      final jb.ApplyReport applied = await host.applyProfile(
        id: profile.id,
        revision: profile.revision,
        requestId: 'app-smoke-apply',
        mode: 'proxy',
      );
      result['applied'] = applied.applied;
      final jb.StartAck stopped = await host.stop(revision: 3);
      result['stopped'] = stopped.accepted;
      final jb.RuntimeStatus idle = await host.status();
      result['idleState'] = idle.state;
      result['ok'] =
          ack.accepted &&
          running.state == 'running' &&
          applied.applied &&
          stopped.accepted &&
          idle.state == 'idle';
    }
  } on Object catch (error) {
    result['error'] = '$error';
  } finally {
    await runtime?.dispose();
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(result)}\n',
      flush: true,
    );
  }
}
