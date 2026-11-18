import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/scaffold/scaffold.dart';
import '../connections/connections_page.dart';
import '../logs/logs_page.dart';
import '../providers/providers_page.dart';

/// FlClash's mobile "More" destination: on phones the requests/logs entries
/// live here instead of the bottom bar (navigation.dart modes
/// `more`/`moreFull`).
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return Scaffold(
      title: l10n.more,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          16 + context.bottomInset,
        ),
        children: [
          Card(
            child: Column(
              children: [
                ListItem(
                  leading: const GlyphIcon(AppGlyphs.connections),
                  title: Text(l10n.connections),
                  onTap: () => Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (_, _, _) => const ConnectionsPage(),
                    ),
                  ),
                ),
                ListItem(
                  leading: const GlyphIcon(AppGlyphs.logs),
                  title: Text(l10n.logs),
                  onTap: () => Navigator.of(context).push(
                    PageRouteBuilder(pageBuilder: (_, _, _) => const LogsPage()),
                  ),
                ),
                ListItem(
                  leading: const GlyphIcon(AppGlyphs.layers),
                  title: Text(l10n.providers),
                  onTap: () => Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (_, _, _) => const ProvidersPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
