import 'package:flutter/widgets.dart';

import 'layout.dart';
import 'system.dart';

// UI constants vendored from FlClash v0.9.3 lib/common/constant.dart, minus the
// Mihomo/core-specific entries (ports, geo files, core timeouts). Each value
// below keeps its upstream meaning; see OUTPUT/A/P0/UI_PARAMETER_LEDGER.csv.

const appName = 'JiejieBox';

/// Upstream app name, kept only for the about page's attribution line.
const upstreamAppName = 'FlClash';
const upstreamVersion = 'v0.9.3';
const upstreamCommit = 'be84736605527034689c95bf27828ff27d912c5e';

const maxTextScale = 1.4;
const minTextScale = 0.8;

const maxMobileWidth = 600;
const maxLaptopWidth = 840;

const defaultPrimaryColor = 0xFF007AFF;

/// Seed used by Prism's default color scheme when the user has not chosen one.
const defaultSeedColor = Color(defaultPrimaryColor);

final double kHeaderHeight = getWindowHeaderHeight(
  isDesktop: system.isDesktop,
  isMacOS: system.isMacOS,
);

const profilesStoreKey = PageStorageKey<String>('profiles');
const toolsStoreKey = PageStorageKey<String>('tools');

/// Throttles re-rendering of high-frequency runtime data (A2/A3).
const renderThrottleDuration = Duration(milliseconds: 300);
