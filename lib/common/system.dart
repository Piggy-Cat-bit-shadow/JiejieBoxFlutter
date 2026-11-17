import 'dart:io';

/// Platform facts the UI reads. Layout never branches on these; it branches on
/// the 600/840 width breakpoints (see layout.dart).
abstract final class system {
  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static bool get isMacOS => Platform.isMacOS;

  static bool get isWindows => Platform.isWindows;

  static bool get isLinux => Platform.isLinux;

  static bool get isAndroid => Platform.isAndroid;

  static bool get isIOS => Platform.isIOS;
}
