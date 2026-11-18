import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../state/app_state.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/scaffold/scaffold.dart';

/// Live logs: level filter, pause (display only), bounded cache and clear.
/// Clearing the local list and clearing the kernel history are two explicit
/// actions, matching the runtime distinction.
class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  static const _levels = ['all', 'info', 'warning', 'error'];

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final runtime = AppStateScope.of(context).runtime;
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) {
        final visible = runtime.logLevel == 'all'
            ? runtime.logs
            : runtime.logs
                  .where((line) => line.level == runtime.logLevel)
                  .toList(growable: false);
        return Scaffold(
          title: l10n.logs,
          iconActions: [
            IconButtonData(
              glyph: runtime.paused ? AppGlyphs.status : AppGlyphs.logs,
              tooltip: runtime.paused ? 'Resume' : 'Pause',
              onPressed: () => runtime.setPaused(!runtime.paused),
            ),
            IconButtonData(
              glyph: AppGlyphs.close,
              tooltip: l10n.clearData,
              onPressed: () {
                runtime.clearLogs();
                runtime.clearKernelLogs();
              },
            ),
          ],
          body: Padding(
            padding: EdgeInsets.only(top: context.contentTopPadding),
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: _levels.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final level = _levels[index];
                      return TonalButton(
                        size: TonalButtonSize.section,
                        label: level == 'all' ? 'All' : level,
                        onPressed: () => runtime.setLogLevel(level),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Text(
                            runtime.loading
                                ? l10n.loading
                                : l10n.nullTip(l10n.logs),
                            style: AppTextStyle.footnote.of(context),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16 + context.bottomInset,
                          ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final line = visible[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '[${_time(line.timeMillis)}] '
                                '${line.level.toUpperCase()} ${line.message}',
                                style: AppTextStyle.footnote
                                    .of(context)
                                    .copyWith(
                                      color: _levelColor(context, line.level),
                                    ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _levelColor(BuildContext context, String level) {
    final scheme = context.colorScheme;
    return switch (level) {
      'error' || 'fatal' => scheme.error,
      'warning' => const Color(0xFFB26A00),
      _ => scheme.onSurface,
    };
  }

  String _time(int millis) {
    if (millis == 0) return '--:--:--';
    final at = DateTime.fromMillisecondsSinceEpoch(millis);
    two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}
