import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../common/layout.dart';
import '../../core/core_connection.dart';
import '../../state/app_state.dart';
import '../../state/runtime_store.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/scaffold/scaffold.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

/// Dashboard, keeping FlClash v0.9.3's card geometry (2/4 columns, three
/// densities, 176/208/56/64/152/176 heights, 440 max column, 16/24 padding)
/// but filling each card with the runtime store's real values instead of a
/// title placeholder.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = AppStateScope.of(context);
    final runtime = state.runtime;
    final scale = textScaleOf(context);
    return Scaffold(
      title: l10n.dashboard,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.status,
          tooltip: l10n.update,
          onPressed: runtime.refreshGroups,
        ),
      ],
      body: AnimatedBuilder(
        animation: Listenable.merge([state, runtime, state.connection]),
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final room = constraints.biggest / scale;
              final density = DashboardDensity.of(room);
              return DashboardDensityScope(
                density: density,
                scale: scale,
                child: density.isDesktop
                    ? _DesktopDashboard(
                        columns: dashboardColumnsOf(room.width),
                        gap: cardSpacingOf(context, state.viewMode),
                      )
                    : _MobileDashboard(
                        gap: cardSpacingOf(context, state.viewMode),
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

double textScaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);

class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({required this.columns, required this.gap});

  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final cards = dashboardCards(context);
    final heights = <double>[
      (compact ? 176 : 208) * scale,
      (compact ? 56 : 64) * scale,
      (compact ? 152 : 176) * scale,
    ];
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        16,
        16,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = constraints.maxWidth - gap * (columns - 1);
          final column = (room / columns).clamp(0.0, 440.0 * scale);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            spacing: gap,
            children: [
              for (var row = 0; row < 3; row++)
                SizedBox(
                  height: heights[row],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: gap,
                    children: [
                      for (var index = 0; index < columns; index++)
                        SizedBox(
                          width: column,
                          child: DashboardMetricCard(
                            data: cards[(row * columns + index) % cards.length],
                            height: heights[row],
                            radius: DashboardCorner.desktopCard,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
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
    final cards = dashboardCards(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(side, 16, side, 24 + context.bottomInset),
      children: [
        for (final (index, card) in cards.take(6).indexed)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: DashboardMetricCard(
              data: card,
              height: (index.isEven ? 176 : 152) * scale,
              radius: DashboardCorner.mobileCard,
            ),
          ),
      ],
    );
  }
}

class DashboardMetric {
  const DashboardMetric({
    required this.title,
    required this.body,
    this.trailing,
  });

  final String title;
  final Widget body;
  final Widget? trailing;
}

class DashboardMetricCard extends StatelessWidget {
  const DashboardMetricCard({
    super.key,
    required this.data,
    required this.height,
    required this.radius,
  });

  final DashboardMetric data;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Card(
        radius: radius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote
                          .of(context, emphasized: true)
                          .copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  if (data.trailing != null) data.trailing!,
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: data.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<DashboardMetric> dashboardCards(BuildContext context) {
  final l10n = context.appLocalizations;
  final state = AppStateScope.of(context);
  final runtime = state.runtime;
  final connection = state.connection;
  final current = runtime.group;
  final selected = current?.selected ?? runtime.currentOutbound;
  return [
    DashboardMetric(
      title: l10n.status,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            selected ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.title2.of(context),
          ),
          const SizedBox(height: 4),
          Text(
            runtime.mode ?? connection.reason ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote.of(context),
          ),
        ],
      ),
      trailing: connection.isAvailable
          ? TonalButton(
              size: TonalButtonSize.section,
              label: connection.state == CoreServiceState.running
                  ? l10n.stop
                  : l10n.start,
              onPressed: () => connection.state == CoreServiceState.running
                  ? state.stopService()
                  : state.startService(),
            )
          : null,
    ),
    DashboardMetric(
      title: l10n.networkSpeed,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RateRow(label: l10n.upload, value: formatRate(runtime.traffic.up)),
          _RateRow(
            label: l10n.download,
            value: formatRate(runtime.traffic.down),
          ),
        ],
      ),
    ),
    DashboardMetric(
      title: l10n.outboundMode,
      body: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final mode in runtime.modes)
            TonalButton(
              size: TonalButtonSize.section,
              label: mode,
              onPressed: () => runtime.setMode(mode),
            ),
          if (runtime.modes.isEmpty)
            Text('—', style: AppTextStyle.body.of(context)),
        ],
      ),
    ),
    DashboardMetric(
      title: l10n.serviceStatus,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            connectionLabel(context, connection),
            style: AppTextStyle.headline.of(context),
          ),
          if (connection.reason != null)
            Text(
              connection.reason!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote.of(context),
            ),
        ],
      ),
    ),
    DashboardMetric(
      title: l10n.profile,
      body: Text(
        state.currentProfile?.label ?? '—',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.title2.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.proxyGroup,
      body: Text(
        runtime.group?.selected ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.headline.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.connectionStats,
      body: Text(
        '${runtime.connectionCount}',
        style: AppTextStyle.title2.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.intranetIP,
      body: Text(
        runtime.intranetIp ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.headline.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.memoryInfo,
      body: Text(
        runtime.memoryBytes == 0 ? '—' : formatBytes(runtime.memoryBytes),
        style: AppTextStyle.title2.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.networkTakeover,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RateRow(
            label: 'System proxy',
            value: state.systemProxyEnabled ? l10n.enabled : l10n.disabled,
          ),
          _RateRow(
            label: 'Auto launch',
            value: state.autostartEnabled ? l10n.enabled : l10n.disabled,
          ),
        ],
      ),
    ),
    DashboardMetric(
      title: l10n.providers,
      body: Text(
        '${runtime.providers.length}',
        style: AppTextStyle.title2.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.connections,
      body: Text(
        '${runtime.activeCount}',
        style: AppTextStyle.title2.of(context),
      ),
    ),
  ];
}

class _RateRow extends StatelessWidget {
  const _RateRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote.of(context),
            ),
          ),
          Text(
            value,
            maxLines: 1,
            style: AppTextStyle.footnote.of(context, emphasized: true),
          ),
        ],
      ),
    );
  }
}

String connectionLabel(BuildContext context, CoreConnection connection) =>
    switch (connection.state) {
      CoreServiceState.unavailable => 'Core unavailable',
      CoreServiceState.stopped => 'Stopped',
      CoreServiceState.starting => 'Starting',
      CoreServiceState.awaitingPermission => 'VPN permission needed',
      CoreServiceState.running => 'Running',
      CoreServiceState.stopping => 'Stopping',
      CoreServiceState.failed => 'Failed',
    };
