import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../providers/providers_page.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/scaffold/scaffold.dart';

/// Settings, following FlClash `ToolsView` (`lib/views/tools.dart:21-99`):
/// grouped `Card` + `ListItem` rows under a page `Scaffold`, with the same
/// 16 dp side padding, `sectionsTopPadding` and `20 + bottomInset` foot.
///
/// P1 only carries settings that exist locally (theme, text scale, navigation
/// shell). Core/network settings arrive with A2/A3.
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  String _themeModeLabel(BuildContext context, ThemeMode mode) {
    final l10n = context.appLocalizations;
    return switch (mode) {
      ThemeMode.system => l10n.system,
      ThemeMode.light => l10n.light,
      ThemeMode.dark => l10n.dark,
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final l10n = context.appLocalizations;
    final trailingStyle = AppTextStyle.footnote.of(context).toLighter;
    return Scaffold(
      title: l10n.tools,
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          Card(
            child: Column(
              children: [
                ListItem(
                  title: Text(l10n.themeMode),
                  trailing: Text(
                    _themeModeLabel(context, state.themeMode),
                    style: trailingStyle,
                  ),
                  onTap: () {
                    final next = switch (state.themeMode) {
                      ThemeMode.system => ThemeMode.light,
                      ThemeMode.light => ThemeMode.dark,
                      ThemeMode.dark => ThemeMode.system,
                    };
                    state.setThemeMode(next);
                  },
                ),
                ListItem(
                  title: Text(l10n.textScale),
                  trailing: Text(
                    '${(state.textScale * 100).round()}%',
                    style: trailingStyle,
                  ),
                  onTap: () =>
                      state.setTextScale(state.textScale >= 1.4 ? 1.0 : 1.4),
                ),
                ListItem(
                  title: Text(l10n.navigationBarStyle),
                  trailing: Text(
                    state.floatingNavigationBar
                        ? l10n.floating
                        : l10n.defaultText,
                    style: trailingStyle,
                  ),
                  onTap: () => state.setFloatingNavigationBar(
                    !state.floatingNavigationBar,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (state.canSystemProxy || state.canAutostart || state.canTray)
            Card(
              child: Column(
                children: [
                  if (state.canSystemProxy)
                    ListItem(
                      title: Text(l10n.systemProxy),
                      trailing: Text(
                        state.systemProxyEnabled ? l10n.enabled : l10n.disabled,
                        style: trailingStyle,
                      ),
                      onTap: () =>
                          state.setSystemProxy(!state.systemProxyEnabled),
                    ),
                  if (state.canAutostart)
                    ListItem(
                      title: Text(l10n.autoLaunch),
                      trailing: Text(
                        state.autostartEnabled ? l10n.enabled : l10n.disabled,
                        style: trailingStyle,
                      ),
                      onTap: () => state.setAutostart(!state.autostartEnabled),
                    ),
                  if (state.canTray)
                    ListItem(
                      title: const Text('Tray icon'),
                      trailing: Text('Active', style: trailingStyle),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: ListItem(
              leading: const GlyphIcon(AppGlyphs.cloudDownload),
              title: const Text('Providers'),
              subtitle: state.providerRefreshStatus == null
                  ? null
                  : Text(state.providerRefreshStatus!),
              trailing: Text(
                state.connection.isAvailable ? 'Refresh' : 'Unavailable',
                style: trailingStyle,
              ),
              onTap: () => state.refreshProviders(),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListItem.open(
              leading: const GlyphIcon(AppGlyphs.layers),
              title: Text(l10n.providers),
              widget: const ProvidersPage(),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListItem.open(
              leading: const GlyphIcon(AppGlyphs.info),
              title: Text(l10n.about),
              widget: const AboutPage(),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final style = AppTextStyle.footnote.of(context).toLighter;
    return Scaffold(
      title: l10n.about,
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text('JiejieBox', style: AppTextStyle.title3.of(context)),
                  Text(
                    'Flutter client for iOS, iPadOS, Android, macOS, Windows.',
                    style: style,
                  ),
                  Text('UI baseline: FlClash v0.9.3 (Prism).', style: style),
                  Text('Core: JiejieBox testing.', style: style),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
