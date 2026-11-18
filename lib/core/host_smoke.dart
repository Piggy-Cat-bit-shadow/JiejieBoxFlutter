import 'dart:convert';
import 'dart:io';

import 'package:jjbox_bridge/jjbox_bridge.dart' as jb;

import 'core_connection.dart';
import 'core_runtime.dart';
import '../state/app_state.dart';

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
        'events': caps.events,
        'systemProxy': caps.systemProxy,
        'autostart': caps.autostart,
        'tray': caps.tray,
      };
      final List<String> eventTypes = <String>[];
      final sub = host.events.listen((event) {
        eventTypes.add(event.callback.type);
      });
      const String config =
          '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}';
      final jb.ProfileWriteResult profile = await host.writeProfile(
        label: 'app-smoke',
        kind: 'local',
        content: utf8.encode(config),
      );
      result['profileId'] = profile.id;
      final CoreConnection connection = CoreConnection(
        bridge: runtime.bridge,
        host: host,
      );
      try {
        final bool started = await connection.start(
          profileId: profile.id,
          profileRevision: profile.revision,
        );
        result['accepted'] = started;
        result['runningState'] = connection.state.name;
        final jb.ApplyReport applied = await connection.applyProfile(
          id: profile.id,
          revision: profile.revision,
        );
        result['applied'] = applied.applied;
        final bool stopped = await connection.stop();
        result['stopped'] = stopped;
        result['idleState'] = connection.state.name;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        result['eventTypes'] = eventTypes;
        result['ok'] =
            started &&
            connection.state.name == 'stopped' &&
            applied.applied &&
            stopped &&
            eventTypes.any((type) => type == 'service.state');
      } finally {
        connection.dispose();
        await sub.cancel();
      }

      // Real node-list import: the kernel parses a share link, the UI assembles
      // a complete profile, and the core accepts/starts it.
      final jb.PreviewResult linkPreview = await host.preview(
        utf8.encode('ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#smoke'),
      );
      final String? composed = composeImportedConfig(
        linkPreview,
        listenPort: 0,
      );
      result['linkPreviewOk'] = linkPreview.ok;
      result['linkItems'] = linkPreview.items.length;
      result['linkComposed'] = composed != null;
      if (composed != null) {
        final jb.ConfigCheckResult check = await host.checkConfig(
          utf8.encode(composed),
        );
        result['linkCheck'] = check.ok;
        final jb.ProfileWriteResult linkProfile = await host.writeProfile(
          label: 'app-smoke-link',
          kind: 'singbox-json',
          content: utf8.encode(composed),
        );
        final jb.StartAck linkAck = await host.start(
          revision: 4,
          mode: 'proxy',
          profileId: linkProfile.id,
          profileRevision: linkProfile.revision,
        );
        final jb.StartAck linkStop = await host.stop(revision: 5);
        result['linkStart'] = linkAck.accepted;
        result['linkStop'] = linkStop.accepted;
        result['ok'] =
            result['ok'] == true &&
            linkPreview.ok &&
            check.ok &&
            linkAck.accepted &&
            linkStop.accepted;
      } else {
        result['ok'] = false;
        result['error'] = 'link list could not be composed';
      }

      // The real UI path: AppState import classifies/composes/validates, then
      // its CoreConnection starts and stops the selected profile.
      final AppState ui = AppState(
        coreConnection: CoreConnection(bridge: runtime.bridge, host: host),
      );
      try {
        await ui.connection.refresh();
        final String? imported = await ui.importConfig(
          label: 'app-smoke-ui-import',
          content: 'ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:8388#ui-import',
          kind: 'link-list',
        );
        result['uiImport'] = imported != null;
        if (imported != null) {
          final bool uiStarted = await ui.startService();
          final bool uiStopped = await ui.stopService();
          result['uiStart'] = uiStarted;
          result['uiStop'] = uiStopped;
          result['uiIdleState'] = ui.connection.state.name;
          result['ok'] =
              result['ok'] == true &&
              uiStarted &&
              uiStopped &&
              ui.connection.state.name == 'stopped';
        } else {
          result['ok'] = false;
          result['error'] = ui.lastActionError ?? 'UI import failed';
        }
      } finally {
        ui.dispose();
      }
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
