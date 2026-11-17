import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/core_connection.dart';
import 'core/core_runtime.dart';
import 'core/host_smoke.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode && Platform.environment['JJBOX_SMOKE'] == '1') {
    await runHostSmoke();
    exit(0);
  }
  final runtime = await createCoreRuntime();
  final state = AppState(
    coreConnection: CoreConnection(bridge: runtime.bridge, host: runtime.host),
  );
  unawaited(state.bootstrap());
  runApp(JiejieBoxApp(state: state));
}
