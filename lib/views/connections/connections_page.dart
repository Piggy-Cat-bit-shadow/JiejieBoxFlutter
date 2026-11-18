import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../state/runtime_store.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/scaffold/scaffold.dart';

/// Live connections, after FlClash's `connections_table` semantics: host, rule,
/// chain and byte counters, with per-row close and close-all.
class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final runtime = AppStateScope.of(context).runtime;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final query = runtime.query.toLowerCase();
        final items = query.isEmpty
            ? runtime.connections
            : runtime.connections
                  .where(
                    (item) =>
                        item.host.toLowerCase().contains(query) ||
                        item.chain.toLowerCase().contains(query),
                  )
                  .toList(growable: false);
        return Scaffold(
          title: l10n.connections,
          iconActions: [
            IconButtonData(
              glyph: AppGlyphs.close,
              tooltip: l10n.closeConnections,
              onPressed: runtime.connections.isEmpty
                  ? null
                  : runtime.closeAllConnections,
            ),
          ],
          body: Column(
            children: [
              SizedBox(height: context.appBarInset),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Card(
                  child: ListItem(
                    leading: const GlyphIcon(AppGlyphs.search),
                    title: TextField(
                      decoration: InputDecoration(
                        hintText: l10n.search,
                        border: const AppInputBorder(),
                      ),
                      onChanged: runtime.setQuery,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          runtime.loading ? l10n.loading : l10n.noData,
                          style: AppTextStyle.footnote.of(context),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          16 + context.bottomInset,
                        ),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return Card(
                            child: ListItem(
                              leading: const GlyphIcon(AppGlyphs.connections),
                              title: Text(
                                item.host.isEmpty
                                    ? item.destination
                                    : item.host,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if (item.rule.isNotEmpty) item.rule,
                                  if (item.chain.isNotEmpty) item.chain,
                                ].join(' / '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 8,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '${formatBytes(item.upload)} / '
                                      '${formatBytes(item.download)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyle.footnote.of(context),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l10n.closeConnection,
                                    icon: const GlyphIcon(AppGlyphs.close),
                                    onPressed: () =>
                                        runtime.closeConnection(item.id),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
