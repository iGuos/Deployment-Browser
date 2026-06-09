import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/data/jenkins_config_repository.dart';
import '../application/status_bar_metrics_provider.dart';
import '../application/workspace_controller.dart';
import '../domain/workspace_tab.dart';

/// 底部状态栏。展示哪些指标由 [statusBarMetricsProvider] 控制（右侧开关菜单可调）。
class WorkspaceStatusBar extends ConsumerWidget {
  const WorkspaceStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final config = ref.watch(jenkinsConfigProvider).value;
    final ws = ref.watch(workspaceProvider);
    final activeTab = ws.activeTab;
    final metrics = ref.watch(statusBarMetricsProvider);

    final chips = <Widget>[];
    if (ws.hasOpenWorkspace) {
      if (metrics.contains(StatusMetric.connection)) {
        chips.add(_Pill(
          icon: config != null ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
          label: config != null
              ? '${l10n.statusConnected} · ${config.displayHost}'
              : l10n.statusNoConfig,
          color: config != null ? palette.success : palette.muted,
        ));
      }
      if (metrics.contains(StatusMetric.project) &&
          activeTab != null &&
          activeTab.kind == WorkspaceTabKind.project) {
        chips.add(_Pill(
          icon: Icons.rocket_launch_rounded,
          label: activeTab.subtitle ?? activeTab.title,
          color: palette.info,
        ));
      }
      if (metrics.contains(StatusMetric.workspaces)) {
        chips.add(_Pill(
          icon: Icons.dashboard_customize_rounded,
          label: l10n.statusWorkspacesCount(ws.openedAccountIds.length),
          color: palette.muted,
        ));
      }
    }

    return Container(
      height: 26,
      color: palette.chromeBar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 11.5, color: palette.muted),
        child: Row(
          children: [
            if (!ws.hasOpenWorkspace)
              _Pill(
                icon: Icons.layers_outlined,
                label: l10n.workspaceStatusNoWorkspace,
                color: palette.muted,
              )
            else
              ..._withSpacing(chips),
            const Spacer(),
            if (ws.hasOpenWorkspace && metrics.contains(StatusMetric.tabs))
              Text(
                l10n.workspaceStatusOpenTabs(ws.tabs.length),
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            const SizedBox(width: 8),
            _MetricsMenu(metrics: metrics),
          ],
        ),
      ),
    );
  }

  List<Widget> _withSpacing(List<Widget> chips) {
    final out = <Widget>[];
    for (var i = 0; i < chips.length; i++) {
      if (i > 0) out.add(const SizedBox(width: 16));
      out.add(chips[i]);
    }
    return out;
  }
}

/// 状态栏右侧的「显示指标」开关菜单。
class _MetricsMenu extends ConsumerWidget {
  const _MetricsMenu({required this.metrics});

  final Set<StatusMetric> metrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);

    String labelFor(StatusMetric m) => switch (m) {
          StatusMetric.connection => l10n.statusMetricConnection,
          StatusMetric.project => l10n.statusMetricProject,
          StatusMetric.workspaces => l10n.statusMetricWorkspaces,
          StatusMetric.tabs => l10n.statusMetricTabs,
        };

    return PopupMenuButton<StatusMetric>(
      tooltip: l10n.statusBarMetricsTooltip,
      icon: Icon(Icons.tune_rounded, size: 13, color: palette.muted),
      iconSize: 13,
      padding: EdgeInsets.zero,
      splashRadius: 12,
      constraints: const BoxConstraints(minWidth: 180),
      // 不自动关闭，便于连续切换多项
      onSelected: (m) => ref.read(statusBarMetricsProvider.notifier).toggle(m),
      itemBuilder: (ctx) => [
        for (final m in StatusMetric.values)
          CheckedPopupMenuItem<StatusMetric>(
            value: m,
            checked: metrics.contains(m),
            child: Text(labelFor(m), style: const TextStyle(fontSize: 12.5)),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
