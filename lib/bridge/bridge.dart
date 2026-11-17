/// C-owned bridge surface for the app.
///
/// The implementation lives in `packages/jjbox_bridge` so it can be tested
/// without the app, and so nothing here depends on the app package name. Pages
/// import this file only; they never see a MethodChannel string.
library;

export 'package:jjbox_bridge/jjbox_bridge.dart';
