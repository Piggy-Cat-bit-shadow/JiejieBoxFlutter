import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/core/host_supervisor.dart';

/// Proves the app-owned lifecycle: the runtime can start the Windows host as a
/// child process (named pipe is the default transport) and stop it again.
void main() {
  final String? exe = _findHost();
  test('supervisor starts the host pipe and stops it', () async {
    final HostSupervisor? supervisor = await HostSupervisor.start(
      executable: exe,
      pipeName: r'\\.\pipe\jjbox-supervisor-test',
      timeout: const Duration(seconds: 8),
    );
    expect(supervisor, isNotNull);
    expect(
      supervisor!.output.any((String line) => line.startsWith('LISTEN pipe:')),
      isTrue,
      reason: supervisor.output.join('\n'),
    );
    final int childPid = supervisor.process.pid;
    await supervisor.stop();
    expect(Process.killPid(childPid), isFalse);
  }, skip: exe == null ? 'core_host.exe not built on this machine' : false);
}

String? _findHost() {
  final String fromEnv = Platform.environment['JJBOX_HOST_EXE'] ?? '';
  if (fromEnv.isNotEmpty && File(fromEnv).existsSync()) return fromEnv;
  final String cwd = Directory.current.path;
  for (final String name in <String>['core_host_libbox.exe', 'core_host.exe']) {
    final File file = File('$cwd/windows/core_host/$name');
    if (file.existsSync()) return file.path;
  }
  return null;
}
