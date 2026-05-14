import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/data/jenkins_config_repository.dart';
import '../application/workspace_controller.dart';
import '../domain/workspace_tab.dart';

/// 底部状态栏。
class WorkspaceStatusBar extends ConsumerWidget {
  const WorkspaceStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final config = ref.watch(jenkinsConfigProvider).value;
    final ws = ref.watch(workspaceProvider);
    final activeTab = ws.activeTab;

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
            else ...[
              _Pill(
                icon: config != null ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                label: config != null
                    ? '${l10n.statusConnected} · ${config.displayHost}'
                    : l10n.statusNoConfig,
                color: config != null ? palette.success : palette.muted,
              ),
              const SizedBox(width: 16),
              if (activeTab != null && activeTab.kind == WorkspaceTabKind.project)
                _Pill(
                  icon: Icons.rocket_launch_rounded,
                  label: activeTab.subtitle ?? activeTab.title,
                  color: palette.info,
                ),
            ],
            const Spacer(),
            Text(
              ws.hasOpenWorkspace ? l10n.workspaceStatusOpenTabs(ws.tabs.length) : '',
              style: TextStyle(color: palette.muted, fontSize: 11.5),
            ),
          ],
        ),
      ),
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
