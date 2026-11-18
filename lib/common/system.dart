import 'dart:io';

import 'package:flutter/foundation.dart';

/// Platform facts the UI reads. Layout never branches on these; it branches on
/// the 600/840 width breakpoints (see layout.dart).
///
/// Production reads `dart:io Platform` (the real host). Tests set
/// [debugPlatformOverride] to render iOS/macOS/Windows on one machine; this is
/// a plain field, not a foundation debug variable, so it cannot leak into
/// Flutter's invariant checks.
abstract final class system {
  /// Test-only; null in production.
  static TargetPlatform? debugPlatformOverride;

  static TargetPlatform get platform {
    final override = debugPlatformOverride;
    if (override != null) return override;
    if (Platform.isMacOS) return TargetPlatform.macOS;
    if (Platform.isWindows) return TargetPlatform.windows;
    if (Platform.isLinux) return TargetPlatform.linux;
    if (Platform.isAndroid) return TargetPlatform.android;
    return TargetPlatform.iOS;
  }

  static bool get isDesktop =>
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;

  static bool get isMobile =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  static bool get isMacOS => platform == TargetPlatform.macOS;

  static bool get isWindows => platform == TargetPlatform.windows;

  static bool get isLinux => platform == TargetPlatform.linux;

  static bool get isAndroid => platform == TargetPlatform.android;

  static bool get isIOS => platform == TargetPlatform.iOS;
}
