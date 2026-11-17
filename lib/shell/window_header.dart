import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../common/constant.dart';
import '../common/system.dart';

/// The desktop title bar the pages render under, following FlClash
/// `lib/manager/window_manager.dart:383-423`:
/// - macOS shows the app name; Windows draws no title (only caption buttons,
///   which belong to window C's plugin);
/// - the bar is a `Surface` with a bottom divider and reserves the measured
///   height (macOS 28, others 32).
///
/// The drag region and caption buttons need the window plugin, so they are
/// omitted here and tracked as a C dependency, not a design change.
class WindowHeader extends StatelessWidget {
  const WindowHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Surface(
      color: colorScheme.surface,
      shape: Border(bottom: Divider.createBorderSide(context)),
      child: SizedBox(
        height: kHeaderHeight,
        child: Stack(
          alignment: AlignmentDirectional.center,
          children: [
            if (system.isMacOS)
              Text(
                appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1.of(context).toLighter,
              ),
          ],
        ),
      ),
    );
  }
}
