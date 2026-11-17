import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Owns the Windows `core_host` child process.
///
/// The host is the only transport that can link the kernel; the C++ plugin and
/// the Dart runtime both expect it to be already listening. Starting it from the
/// app (rather than asking the user to run a command) is what makes the product
/// path real. The host is started with `--parent-pid`, so it also exits if the
/// app crashes; [stop] is used when startup fails or a test disposes it.
class HostSupervisor {
  HostSupervisor._(this.executable, this.process);

  final String executable;
  final Process process;
  final List<String> output = <String>[];
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  bool _stopped = false;

  static Future<HostSupervisor?> start({
    String? executable,
    String pipeName = r'\\.\pipe\jjbox-host',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!Platform.isWindows) return null;
    final String? exe = executable ?? _findExecutable();
    if (exe == null) {
      _log('find: no core_host executable');
      return null;
    }
    final Directory dataDir = _dataDirectory();
    _log('start: exe=$exe data=${dataDir.path}');
    try {
      await dataDir.create(recursive: true);
    } on Object catch (error) {
      _log('data dir failed: $error');
      return null;
    }
    final Process process;
    try {
      process = await Process.start(exe, <String>[
        '--pipe',
        pipeName,
        '--data',
        dataDir.path,
        '--parent-pid',
        pid.toString(),
      ]);
    } on Object catch (error) {
      _log('spawn failed: $error');
      return null;
    }
    final HostSupervisor supervisor = HostSupervisor._(exe, process);
    final Completer<bool> ready = Completer<bool>();
    supervisor._stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (String line) {
            supervisor.output.add(line);
            if (line.startsWith('LISTEN pipe:') && !ready.isCompleted) {
              ready.complete(true);
            }
          },
          onDone: () {
            if (!ready.isCompleted) ready.complete(false);
          },
          onError: (Object _) {
            if (!ready.isCompleted) ready.complete(false);
          },
        );
    supervisor._stderr = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(supervisor.output.add);

    bool started;
    try {
      started = await ready.future.timeout(timeout);
    } on TimeoutException {
      started = false;
    }
    if (!started) {
      _log('not ready: ${supervisor.output.join(' | ')}');
      await supervisor.stop();
      return null;
    }
    _log('ready: ${supervisor.output.join(' | ')}');
    return supervisor;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _stdout?.cancel();
    await _stderr?.cancel();
    try {
      process.kill();
    } on Object {
      // already gone
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on Object {
      // the watchdog/OS already reaped it
    }
  }

  static String? _findExecutable() {
    final String fromEnv = Platform.environment['JJBOX_HOST_EXE'] ?? '';
    if (fromEnv.isNotEmpty && File(fromEnv).existsSync()) return fromEnv;
    final String appDir = File(Platform.resolvedExecutable).parent.path;
    final String cwd = Directory.current.path;
    final List<String> dirs = <String>[
      appDir,
      cwd,
      '$cwd\\windows\\core_host',
      '$cwd\\build\\windows\\x64\\runner\\Debug',
      '$cwd\\build\\windows\\x64\\runner\\Release',
    ];
    for (final String dir in dirs) {
      for (final String name in <String>[
        'core_host_libbox.exe',
        'core_host.exe',
      ]) {
        final File candidate = File('$dir\\$name');
        if (candidate.existsSync()) return candidate.path;
      }
    }
    return null;
  }

  static Directory _dataDirectory() {
    final String localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    if (localAppData.isNotEmpty) {
      return Directory('$localAppData\\JiejieBox\\host');
    }
    return Directory('${Directory.systemTemp.path}\\JiejieBox\\host');
  }

  static void _log(String message) {
    try {
      final Directory dir = _dataDirectory();
      dir.createSync(recursive: true);
      File('${dir.path}\\supervisor.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // Diagnostics must never decide whether the host starts.
    }
  }
}
