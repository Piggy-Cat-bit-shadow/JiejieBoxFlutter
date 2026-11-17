import 'dart:async';
import 'dart:io';

import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_bridge.dart';
import 'host_core_bridge.dart';

/// The runtime the app root installs: a [CoreBridge] plus, when a real host is
/// reachable, the typed [jb.HostBridge] used for profile/config/service calls.
class CoreRuntime {
  const CoreRuntime(this.bridge, [this.host]);

  final CoreBridge bridge;
  final jb.HostBridge? host;

  bool get isReal => host != null;
}

/// Builds the production bridge.
///
/// Transport choice (contract §2/§7):
/// - a loopback socket when `JJBOX_HOST_ENDPOINT=host:port` is provided (the
///   Windows host a runner can start);
/// - otherwise the `jjbox/host` MethodChannel the mobile/macOS plugins use.
///
/// The capability probe decides availability: no plugin, no socket or a
/// timeout all end as [UnavailableCoreBridge] with the reason, never as a fake
/// "connected" state.
Future<CoreRuntime> createCoreRuntime({
  jb.HostTransport? transport,
  String? endpoint,
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
  chosen ??= jb.MethodChannelHostTransport();
  final jb.HostBridge host = jb.HostBridge(
    transport: chosen,
    timeout: const Duration(seconds: 20),
  );
  try {
    await host.capabilities().timeout(probeTimeout);
    return CoreRuntime(HostCoreBridge(host), host);
  } on Object catch (error) {
    await host.dispose();
    final String detail = transportFailure == null
        ? '$error'
        : '$transportFailure; $error';
    return CoreRuntime(
      UnavailableCoreBridge('Host bridge unavailable: $detail'),
    );
  }
}

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
