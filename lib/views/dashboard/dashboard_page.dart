import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../common/layout.dart';
import '../../state/app_state.dart';
import '../../ui/scaffold/scaffold.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

/// The dashboard's layout shell, ported from FlClash v0.9.3
/// `lib/views/dashboard/dashboard.dart` (`_DashboardViewState.build` and
/// `_DesktopDashboard`). All geometry is upstream's: 2/4 columns, three
/// densities, 176/208, 56/64, 152/176, 112/120 row heights, 440 max column
/// width, 16/24/24 page padding.
///
/// Cards carry their real titles and no values: the runtime data arrives in A2
/// (CONTRACTS K6-K13). Nothing here shows a simulated connected/updated state.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = AppStateScope.of(context);
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final gap = cardSpacingOf(context, state.viewMode);
    return Scaffold(
      title: l10n.dashboard,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.biggest / scale;
          final density = DashboardDensity.of(room);
          return DashboardDensityScope(
            density: density,
            scale: scale,
            child: density.isDesktop
                ? _DesktopDashboard(
                    columns: dashboardColumnsOf(room.width),
                    gap: gap,
                  )
                : _MobileDashboard(gap: gap),
          );
        },
      ),
    );
  }
}

class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({required this.columns, required this.gap});

  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final base = EdgeInsetsDirectional.fromSTEB(
      16,
      context.contentTopPadding,
      24,
      24 + MediaQuery.paddingOf(context).bottom,
    );
    final topHeight = (compact ? 176 : 208) * scale;
    final controlHeight = (compact ? 56 : 64) * scale;
    final middleHeight = (compact ? 152 : 176) * scale;
    final titles = _titles(context);
    return Padding(
      padding: base,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.maxWidth - gap * (columns - 1);
          final column = math.min(room / columns, 440 * scale);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: gap,
            children: [
              _row(context, topHeight, column, titles, 0),
              _row(context, controlHeight, column, titles, columns),
              _row(context, middleHeight, column, titles, columns * 2),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context,
    double height,
    double column,
    List<String> titles,
    int start,
  ) {
    return SizedBox(
      height: height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: gap,
        children: [
          for (var index = 0; index < columns; index++)
            SizedBox(
              width: column,
              child: _DashboardCard(
                title: titles[(start + index) % titles.length],
                height: height,
                radius: DashboardCorner.desktopCard,
              ),
            ),
        ],
      ),
    );
  }
}

class _MobileDashboard extends StatelessWidget {
  const _MobileDashboard({required this.gap});

  final double gap;

  @override
  Widget build(BuildContext context) {
    final scale = DashboardDensityScope.scaleOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final side = dashboardMobileSideOf(width);
    final titles = _titles(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        side,
        context.contentTopPadding,
        side,
        24 + context.bottomInset,
      ),
      children: [
        for (final (index, title) in titles.take(6).indexed)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: _DashboardCard(
              title: title,
              height: (index.isEven ? 176 : 152) * scale,
              radius: DashboardCorner.mobileCard,
            ),
          ),
      ],
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.height,
    required this.radius,
  });

  final String title;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return SizedBox(
      height: height,
      child: Card(
        radius: radius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: AlignmentDirectional.topStart,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote
                  .of(context, emphasized: true)
                  .copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

List<String> _titles(BuildContext context) {
  final l10n = context.appLocalizations;
  return [
    l10n.status,
    l10n.networkSpeed,
    l10n.outboundMode,
    l10n.serviceStatus,
    l10n.profile,
    l10n.proxyGroup,
    l10n.connectionStats,
    l10n.intranetIP,
    l10n.memoryInfo,
    l10n.networkTakeover,
    l10n.profile,
    l10n.proxyGroup,
  ];
}
