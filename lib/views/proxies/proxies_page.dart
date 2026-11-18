import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../state/runtime_store.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/scaffold/scaffold.dart';

/// Proxies, ported in structure from FlClash v0.9.3 `lib/views/proxies/`:
/// group tabs, a searchable outbound list with latency, selection and a
/// group-level URL test. The data is the runtime store, never a fixture in the
/// production path.
class ProxiesPage extends StatelessWidget {
  const ProxiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = AppStateScope.of(context);
    final runtime = state.runtime;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final group = runtime.group;
        return Scaffold(
          title: l10n.proxies,
          iconActions: [
            IconButtonData(
              glyph: AppGlyphs.speed,
              tooltip: l10n.testUrl,
              onPressed: group == null
                  ? null
                  : () => runtime.urlTest(group.tag),
            ),
            IconButtonData(
              glyph: AppGlyphs.status,
              tooltip: 'Refresh',
              onPressed: runtime.refreshGroups,
            ),
          ],
          body: Column(
            children: [
              SizedBox(height: context.appBarInset),
              if (runtime.groups.isNotEmpty)
                _GroupTabs(
                  groups: runtime.groups,
                  active: group?.tag,
                  onSelected: runtime.selectGroup,
                ),
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
              if (runtime.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Card(
                    child: ListItem(
                      leading: const GlyphIcon(AppGlyphs.close),
                      title: Text(runtime.error!),
                    ),
                  ),
                ),
              Expanded(
                child: group == null || runtime.visibleNodes.isEmpty
                    ? Center(
                        child: Text(
                          runtime.loading
                              ? l10n.loading
                              : runtime.groups.isEmpty
                              ? l10n.proxyGroupEmpty
                              : l10n.clearSearch,
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
                        itemCount: runtime.visibleNodes.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final node = runtime.visibleNodes[index];
                          return Card(
                            child: ListItem(
                              leading: const GlyphIcon(AppGlyphs.status),
                              title: Text(
                                node.tag,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(node.type),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 8,
                                children: [
                                  Text(
                                    node.latencyLabel,
                                    style: AppTextStyle.footnote
                                        .of(context)
                                        .copyWith(
                                          color: _delayColor(context, node),
                                        ),
                                  ),
                                  if (node.selected)
                                    const SelectionBadge(size: 20),
                                ],
                              ),
                              onTap: () => runtime.select(group.tag, node.tag),
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

  Color _delayColor(BuildContext context, ProxyNodeView node) {
    final scheme = context.colorScheme;
    if (node.testing) return scheme.onSurfaceVariant;
    final delay = node.delay;
    if (delay == null || delay < 0 || delay > 500) return scheme.error;
    if (delay > 200) return const Color(0xFFB26A00);
    return const Color(0xFF2E7D32);
  }
}

class _GroupTabs extends StatelessWidget {
  const _GroupTabs({
    required this.groups,
    required this.active,
    required this.onSelected,
  });

  final List<ProxyGroupView> groups;
  final String? active;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final group = groups[index];
          return TonalButton(
            size: TonalButtonSize.section,
            label: group.tag,
            onPressed: () => onSelected(group.tag),
          );
        },
      ),
    );
  }
}
