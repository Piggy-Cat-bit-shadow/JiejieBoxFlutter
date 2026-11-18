import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../common/context.dart';
import '../../common/enums.dart';
import '../../common/layout.dart';
import '../../core/core_connection.dart';
import '../../state/app_state.dart';
import '../../state/runtime_store.dart';
import '../../ui/icons/app_glyphs.dart';
import '../../ui/scaffold/scaffold.dart';
import '../proxies/proxies_page.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

/// Dashboard laid out like FlClash v0.9.3: a 2-wide status card, separate
/// upload/download cards, a 2-wide mode strip with system-proxy/TUN switches,
/// four quarter cards and a 2+2 bottom row. Geometry (heights, radius, 440 max
/// column, 16/24 padding) is upstream's; values come from the runtime store.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final state = AppStateScope.of(context);
    return Scaffold(
      title: l10n.dashboard,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.verified,
          tooltip: l10n.update,
          onPressed: state.runtime.refreshGroups,
        ),
      ],
      body: AnimatedBuilder(
        animation: Listenable.merge([state, state.runtime, state.connection]),
        builder: (context, _) {
          final room = MediaQuery.sizeOf(context) /
              MediaQuery.textScalerOf(context).scale(1);
          final density = DashboardDensity.of(room);
          return DashboardDensityScope(
            density: density,
            scale: DashboardDensityScope.scaleOf(context),
            child: density.isDesktop
                ? _DesktopDashboard(
                    gap: cardSpacingOf(context, state.viewMode),
                  )
                : _MobileDashboard(gap: cardSpacingOf(context, state.viewMode)),
          );
        },
      ),
    );
  }
}

class _DesktopDashboard extends StatelessWidget {
  const _DesktopDashboard({required this.gap});

  final double gap;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final cards = dashboardCards(context);
    final tall = (compact ? 176 : 208) * scale;
    final control = (compact ? 56 : 64) * scale;
    final quarter = (compact ? 152 : 176) * scale;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final rows = <(double, List<(int, DashboardMetric)>)>[
      if (wide) ...[
        (tall, [(2, cards[0]), (1, cards[1]), (1, cards[2])]),
        (control, [(2, cards[3]), (1, cards[4]), (1, cards[5])]),
        (quarter, [(1, cards[6]), (1, cards[7]), (1, cards[8]), (1, cards[9])]),
        (quarter, [(2, cards[10]), (2, cards[11])]),
      ] else ...[
        (tall, [(1, cards[0])]),
        (control + 96 * scale, [(1, cards[1]), (1, cards[2])]),
        (control, [(1, cards[3])]),
        (control, [(1, cards[4]), (1, cards[5])]),
        (quarter, [(1, cards[6]), (1, cards[7])]),
        (quarter, [(1, cards[8]), (1, cards[9])]),
        (quarter, [(1, cards[10])]),
        (quarter, [(1, cards[11])]),
      ],
    ];
    return SingleChildScrollView(
      padding: EdgeInsetsDirectional.fromSTEB(
        16,
        context.contentTopPadding,
        24,
        24 + context.bottomInset,
      ),
      child: Column(
        spacing: gap,
        children: [
          for (final (height, row) in rows)
            SizedBox(
              height: height,
              child: Row(
                spacing: gap,
                children: [
                  for (final (flex, card) in row)
                    Expanded(
                      flex: flex,
                      child: DashboardMetricCard(
                        data: card,
                        height: height,
                        radius: DashboardCorner.desktopCard,
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

class _MobileDashboard extends StatelessWidget {
  const _MobileDashboard({required this.gap});

  final double gap;

  @override
  Widget build(BuildContext context) {
    final side = dashboardMobileSideOf(MediaQuery.sizeOf(context).width);
    final cards = dashboardCards(context);
    final mobile = <Widget>[
      DashboardMetricCard(
        data: cards[0],
        radius: DashboardCorner.mobileCard,
      ),
      DashboardMetricCard(
        data: _speedCard(context),
        radius: DashboardCorner.mobileCard,
      ),
      for (final card in cards.skip(3))
        DashboardMetricCard(data: card, radius: DashboardCorner.mobileCard),
    ];
    return ListView(
      padding: EdgeInsets.fromLTRB(
        side,
        context.contentTopPadding,
        side,
        24 + context.bottomInset,
      ),
      children: [
        for (final card in mobile)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: card,
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
    this.onTap,
    this.compact = false,
  });

  final String title;
  final Widget body;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Control-row cards put the title and the value on one line (FlClash's
  /// mode / takeover strips), so a 56/64 px row does not overflow.
  final bool compact;
}

class DashboardMetricCard extends StatelessWidget {
  const DashboardMetricCard({
    super.key,
    required this.data,
    this.height,
    required this.radius,
  });

  final DashboardMetric data;

  /// Desktop rows are fixed height; mobile cards size to their content, as in
  /// FlClash's mobile dashboard.
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final content = Card(
        radius: radius,
        onPressed: data.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: data.compact
              ? Row(
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
                    Flexible(child: data.body),
                    if (data.trailing != null) data.trailing!,
                  ],
                )
              : Column(
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
              if (height != null)
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: data.body,
                  ),
                )
              else
                data.body,
            ],
          ),
        ),
      );
    final card = content;
    return height == null
        ? card
        : SizedBox(height: height, child: card);
  }
}

List<DashboardMetric> dashboardCards(BuildContext context) {
  final l10n = context.appLocalizations;
  final state = AppStateScope.of(context);
  final runtime = state.runtime;
  final connection = state.connection;
  final selected = runtime.group?.selected ?? runtime.currentOutbound;
  final service = connectionLabel(connection);
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
            runtime.mode ?? controlReason(connection),
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
      onTap: () => state.setPage(PageLabel.proxies),
    ),
    _trafficCard(context, upload: true),
    _trafficCard(context, upload: false),
    DashboardMetric(
      title: l10n.outboundMode,
      compact: true,
      body: runtime.modes.isEmpty
          ? Text('—', style: AppTextStyle.body.of(context))
          : Row(
              spacing: 8,
              children: [
                for (final mode in runtime.modes.take(3))
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: TonalButton(
                        size: TonalButtonSize.section,
                        label: mode,
                        onPressed: () => runtime.setMode(mode),
                      ),
                    ),
                  ),
              ],
            ),
    ),
    DashboardMetric(
      compact: true,
      title: 'System proxy',
      body: Text(
        state.systemProxyEnabled ? l10n.enabled : l10n.disabled,
        style: AppTextStyle.headline.of(context),
      ),
    ),
    DashboardMetric(
      compact: true,
      title: 'TUN',
      body: Text(
        connection.runtimeStatus?.tunActive == true
            ? l10n.enabled
            : l10n.disabled,
        style: AppTextStyle.headline.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.intranetIP,
      body: Text(
        runtime.intranetIp ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.title2.of(context),
      ),
    ),
    DashboardMetric(
      title: l10n.profile,
      body: Text(
        state.currentProfile?.label ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyle.headline.of(context),
      ),
      onTap: () => state.setPage(PageLabel.profiles),
    ),
    DashboardMetric(
      title: l10n.serviceStatus,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(service, style: AppTextStyle.headline.of(context)),
          if (connection.reason != null)
            Text(
              connection.reason!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote.of(context),
            ),
        ],
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
      title: l10n.connectionStats,
      body: _Counts(
        first: runtime.connections.length,
        second: runtime.connectionCount,
        firstLabel: l10n.connections,
        secondLabel: 'Recent',
      ),
      onTap: () => state.setPage(PageLabel.connections),
    ),
    DashboardMetric(
      title: l10n.proxyGroup,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            runtime.group?.tag ?? '—',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.headline.of(context),
          ),
          Text(
            runtime.group?.selected ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote.of(context),
          ),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        PageRouteBuilder(pageBuilder: (_, _, _) => const ProxiesPage()),
      ),
    ),
  ];
}

DashboardMetric _trafficCard(BuildContext context, {required bool upload}) {
  final l10n = context.appLocalizations;
  final runtime = AppStateScope.of(context).runtime;
  final value = upload ? runtime.traffic.up : runtime.traffic.down;
  final total = upload ? runtime.traffic.upTotal : runtime.traffic.downTotal;
  return DashboardMetric(
    title: upload ? l10n.upload : l10n.download,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(formatRate(value), style: AppTextStyle.title2.of(context)),
        Text(
          'Total ${formatBytes(total)}',
          style: AppTextStyle.footnote.of(context),
        ),
      ],
    ),
  );
}

class _Counts extends StatelessWidget {
  const _Counts({
    required this.first,
    required this.second,
    required this.firstLabel,
    required this.secondLabel,
  });

  final int first;
  final int second;
  final String firstLabel;
  final String secondLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _Count(value: first, label: firstLabel)),
        Expanded(child: _Count(value: second, label: secondLabel)),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: AppTextStyle.title2.of(context)),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.footnote.of(context),
        ),
      ],
    );
  }
}

String controlReason(CoreConnection connection) =>
    connection.reason ?? connectionLabel(connection);

String connectionLabel(CoreConnection connection) => switch (connection.state) {
  CoreServiceState.unavailable => 'Core unavailable',
  CoreServiceState.stopped => 'Stopped',
  CoreServiceState.starting => 'Starting',
  CoreServiceState.awaitingPermission => 'VPN permission needed',
  CoreServiceState.running => 'Running',
  CoreServiceState.stopping => 'Stopping',
  CoreServiceState.failed => 'Failed',
};


DashboardMetric _speedCard(BuildContext context) {
  final l10n = context.appLocalizations;
  final runtime = AppStateScope.of(context).runtime;
  Widget cell(String label, int rate, int total) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        shape: AppShape.all(AppCorner.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyle.footnote.of(context)),
          const SizedBox(height: 4),
          Text(formatRate(rate), style: AppTextStyle.title2.of(context)),
          Text(
            'Total ${formatBytes(total)}',
            style: AppTextStyle.footnote.of(context),
          ),
        ],
      ),
    ),
  );
  return DashboardMetric(
    title: l10n.networkSpeed,
    body: Row(
      spacing: 8,
      children: [
        cell(l10n.upload, runtime.traffic.up, runtime.traffic.upTotal),
        cell(l10n.download, runtime.traffic.down, runtime.traffic.downTotal),
      ],
    ),
  );
}
