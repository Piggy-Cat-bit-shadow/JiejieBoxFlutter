import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../common/enums.dart';
import '../state/app_state.dart';

/// The scopes Prism expects above every page, plus the view-size capture that
/// replaces FlClash's ThemeManager LayoutBuilder.
///
/// Order matters: ViewScope must sit above the pages the shell builds, and
/// MeasureScope above anything that measures text (cards, bars, lists).
class AppScopes extends StatelessWidget {
  const AppScopes({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Reporting during build would notify mid-frame; defer to the frame end.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          state.updateViewSize(size);
        });
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        return ViewScope(
          size: size,
          isMobile: state.viewMode == ViewMode.mobile,
          windowControls: Size.zero,
          child: MeasureScope(
            measure: Measure.of(context, textScale),
            child: child,
          ),
        );
      },
    );
  }
}
