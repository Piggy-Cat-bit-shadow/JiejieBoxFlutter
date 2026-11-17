import 'dart:async';
import 'dart:io';

import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_bridge.dart';
import 'host_core_bridge.dart';
import 'host_supervisor.dart';

/// The runtime the app root installs: a [CoreBridge] plus, when a real host is
/// reachable, the typed [jb.HostBridge] used for profile/config/service calls.
class CoreRuntime {
  CoreRuntime(this.bridge, [this.host, this.supervisor]);

  final CoreBridge bridge;
  final jb.HostBridge? host;
  final HostSupervisor? supervisor;

  bool get isReal => host != null;

  Future<void> dispose() async {
    await host?.dispose();
    await supervisor?.stop();
  }
}

/// Builds the production bridge.
///
/// Transport choice (contract §2/§7):
/// - a loopback socket when `JJBOX_HOST_ENDPOINT=host:port` is provided (tests
///   and diagnostics);
/// - otherwise the Windows `core_host` is started as a child process and the
///   `jjbox/host` MethodChannel (named pipe) the plugins use;
/// - on mobile/macOS the plugin is in-process and no child is started.
///
/// The capability probe decides availability: no plugin, no socket or a timeout
/// all end as [UnavailableCoreBridge] with the reason, never as a fake
/// "connected" state.
Future<CoreRuntime> createCoreRuntime({
  jb.HostTransport? transport,
  String? endpoint,
  bool? spawnHost,
  Duration probeTimeout = const Duration(seconds: 3),
}) async {
  final String? target = endpoint ?? _endpointFromEnvironment();
  jb.HostTransport? chosen = transport;
  String? transportFailure;
  if (chosen == null && target != null && target.isNotEmpty) {
    final Uri? uri = Uri.tryParse('tcp://$target');
    if (uri != null && uri.host.isNotEmpty && uri.port != 0) {
      try {
        chosen = await jb.SocketHostTransport.connect(uri.host, uri.port);
      } catch (error) {
        transportFailure = 'socket $target: $error';
      }
    }
  }

  HostSupervisor? supervisor;
  if (chosen == null && (spawnHost ?? _shouldSpawnHost())) {
    supervisor = await HostSupervisor.start();
    if (supervisor == null) {
      transportFailure ??= 'core host process was not started';
    }
  }

  chosen ??= jb.MethodChannelHostTransport();
  final jb.HostBridge host = jb.HostBridge(
    transport: chosen,
    timeout: const Duration(seconds: 20),
  );
  final DateTime deadline = DateTime.now().add(probeTimeout);
  Object? lastError;
  while (true) {
    try {
      await host.capabilities().timeout(const Duration(seconds: 1));
      return CoreRuntime(HostCoreBridge(host), host, supervisor);
    } on Object catch (error) {
      lastError = error;
    }
    if (!DateTime.now().isBefore(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  await host.dispose();
  await supervisor?.stop();
  final String detail = transportFailure == null
      ? '$lastError'
      : '$transportFailure; $lastError';
  _log('probe failed: $detail');
  return CoreRuntime(UnavailableCoreBridge('Host bridge unavailable: $detail'));
}

void _log(String message) {
  try {
    final String localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final Directory dir = localAppData.isNotEmpty
        ? Directory('$localAppData\\JiejieBox\\host')
        : Directory('${Directory.systemTemp.path}\\JiejieBox\\host');
    dir.createSync(recursive: true);
    File('${dir.path}\\runtime.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // Diagnostics must not change availability.
  }
}

bool _shouldSpawnHost() =>
    Platform.isWindows && Platform.environment['FLUTTER_TEST'] != 'true';

String? _endpointFromEnvironment() {
  final String fromEnv = Platform.environment['JJBOX_HOST_ENDPOINT'] ?? '';
  if (fromEnv.isNotEmpty) {
    return fromEnv;
  }
  const String fromDefine = String.fromEnvironment(
    'JJBOX_HOST_ENDPOINT',
    defaultValue: '',
  );
  return fromDefine.isEmpty ? null : fromDefine;
}
