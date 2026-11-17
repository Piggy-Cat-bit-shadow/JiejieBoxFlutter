import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../common/context.dart';
import '../common/enums.dart';
import '../common/layout.dart';
import '../common/system.dart';
import '../state/app_state.dart';
import '../ui/icons/app_glyphs.dart';
import '../ui/null_status_illustration.dart';
import '../ui/scaffold/scaffold.dart';
import '../views/dashboard/dashboard_page.dart';
import '../views/profiles/profiles_page.dart';
import '../views/tools/tools_page.dart';
import 'window_header.dart';

class _NavItem {
  const _NavItem(this.label, this.glyph, this.builder);

  final PageLabel label;
  final Glyph glyph;
  final WidgetBuilder builder;
}

/// The app shell: sidebar on laptop/desktop, bottom bar on mobile, adapted from
/// FlClash `lib/pages/home.dart` + `lib/manager/app_manager.dart`.
///
/// Differences that are deliberate and tracked in PRISM_BASELINE_DIFF.md:
/// - one persistent page instead of a PageView (no swipe/tab animation yet);
/// - desktop caption buttons are window C's plugin, so the bar only reserves
///   the measured height and a drag region;
/// - the "proxies" item stays hidden until the data layer reports groups,
///   exactly as FlClash hides it when `hasProxies` is false.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  List<_NavItem> _items(BuildContext context) {
    return [
      _NavItem(
        PageLabel.dashboard,
        AppGlyphs.dashboard,
        (_) => const DashboardPage(),
      ),
      _NavItem(
        PageLabel.profiles,
        AppGlyphs.profiles,
        (_) => const ProfilesPage(),
      ),
      _NavItem(PageLabel.tools, AppGlyphs.tools, (_) => const ToolsPage()),
    ];
  }

  Widget _pageFor(PageLabel label) => switch (label) {
    PageLabel.profiles => const ProfilesPage(),
    PageLabel.tools => const ToolsPage(),
    PageLabel.dashboard => const DashboardPage(),
    PageLabel.proxies => const _MissingPage(title: 'Proxies'),
  };

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final items = _items(context);
    final page = _pageFor(state.page);

    final showsHeader = showsWindowHeader(
      isDesktop: system.isDesktop,
      isMacOS: system.isMacOS,
      // Window C supplies the real OS version; modern macOS always draws it.
      version: 14,
      isMobileView: state.isMobileView,
    );

    final content = state.isMobileView
        ? _MobileShell(items: items, state: state, page: page)
        : _DesktopShell(items: items, state: state, page: page);

    return Surface(
      color: SurfaceLevel.page.colorOf(context.colorScheme),
      child: Column(
        children: [
          if (showsHeader) const WindowHeader(),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.items,
    required this.state,
    required this.page,
  });

  final List<_NavItem> items;
  final AppState state;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    final canExpand = canExpandSidebar(state.viewMode);
    return Row(
      children: [
        NavigationSidebar(
          destinations: [
            for (final item in items)
              SidebarDestination(
                glyph: item.glyph,
                label: item.label == PageLabel.dashboard
                    ? context.appLocalizations.dashboard
                    : item.label == PageLabel.profiles
                    ? context.appLocalizations.profiles
                    : context.appLocalizations.tools,
              ),
          ],
          selectedIndex: _indexOf(items, state.page),
          expanded: canExpand && state.sidebarExpanded,
          onSelected: (index) => state.setPage(items[index].label),
          onToggle: canExpand
              ? () => state.setSidebarExpanded(!state.sidebarExpanded)
              : null,
          windowControls: system.isMacOS
              ? macOSTrafficLightsArea
              : Size.zero,
        ),
        Expanded(
          child: ClipRect(
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeRight: true,
              child: page,
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.items,
    required this.state,
    required this.page,
  });

  final List<_NavItem> items;
  final AppState state;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    final index = _indexOf(items, state.page);
    final bar = state.floatingNavigationBar
        ? NavigationDock(
            destinations: [
              for (final item in items)
                NavigationDockDestination(
                  glyph: item.glyph,
                  label: _labelOf(context, item.label),
                ),
            ],
            selectedIndex: index,
            onSelected: (value) => state.setPage(items[value].label),
          )
        : NavigationBar(
            destinations: [
              for (final item in items)
                NavigationDestination(
                  icon: AnimatedGlyph(
                    glyph: item.glyph,
                    filled: item.label == state.page,
                  ),
                  label: _labelOf(context, item.label),
                ),
            ],
            selectedIndex: index,
            onDestinationSelected: (value) => state.setPage(items[value].label),
          );
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: page,
          ),
        ),
        bar,
      ],
    );
  }
}

String _labelOf(BuildContext context, PageLabel label) {
  final l10n = context.appLocalizations;
  return switch (label) {
    PageLabel.dashboard => l10n.dashboard,
    PageLabel.proxies => l10n.proxies,
    PageLabel.profiles => l10n.profiles,
    PageLabel.tools => l10n.tools,
  };
}

int _indexOf(List<_NavItem> items, PageLabel label) {
  final index = items.indexWhere((item) => item.label == label);
  return index < 0 ? 0 : index;
}

/// A page whose data layer has not landed yet. It renders the real page shell
/// and says so; it never shows a simulated "connected" or "updated" state.
class _MissingPage extends StatelessWidget {
  const _MissingPage({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: title,
      body: NullStatusSwitcher(
        isEmpty: true,
        nullStatus: NullStatus(
          label: title,
          description: '数据面在 A2 接入',
          illustration: NullStatusIllustration.profile,
        ),
        child: const SizedBox.shrink(),
      ),
    );
  }
}
