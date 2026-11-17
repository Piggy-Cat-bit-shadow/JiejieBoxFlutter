import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/core_connection.dart';
import 'core/core_runtime.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = await createCoreRuntime();
  final state = AppState(
    coreConnection: CoreConnection(bridge: runtime.bridge, host: runtime.host),
  );
  unawaited(state.bootstrap());
  runApp(JiejieBoxApp(state: state));
}
