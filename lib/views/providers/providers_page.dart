import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../state/runtime_store.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/list_item.dart';
import '../../ui/scaffold/scaffold.dart';

/// Provider list and refresh. `supported:false` and failures are shown as the
/// host's answer; nodes already loaded are kept.
class ProvidersPage extends StatelessWidget {
  const ProvidersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final runtime = AppStateScope.of(context).runtime;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        return Scaffold(
          title: context.appLocalizations.providers,
          iconActions: [
            IconButtonData(
              glyph: AppGlyphs.status,
              tooltip: 'Refresh',
              onPressed: runtime.refreshProviders,
            ),
          ],
          body: Padding(
            padding: EdgeInsets.only(top: context.contentTopPadding),
            child: runtime.providers.isEmpty
                ? Center(
                    child: Text(
                      runtime.providerError ??
                          (runtime.loading
                              ? context.appLocalizations.loading
                              : context.appLocalizations.emptyFallback),
                      style: AppTextStyle.footnote.of(context),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      16 + context.bottomInset,
                    ),
                    itemCount: runtime.providers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final provider = runtime.providers[index];
                      return Card(
                        child: ListItem(
                          leading: const GlyphIcon(AppGlyphs.layers),
                          title: Text(provider.name),
                          subtitle: Text(
                            '${provider.type} · ${provider.vehicle} · '
                            '${provider.nodeCount} nodes'
                            '${provider.updatedAtMillis == 0 ? '' : ' · ${formatRelative(provider.updatedAtMillis)}'}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Refresh',
                            icon: const GlyphIcon(AppGlyphs.status),
                            onPressed: runtime is HostRuntimeStore
                                ? () => (runtime).refreshProvider(provider.name)
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
