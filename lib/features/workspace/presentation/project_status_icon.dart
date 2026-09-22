import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/building_pulse.dart';
import '../../release/application/release_controller.dart';

/// 项目图标的状态色：发版中 / 成功 / 失败 / 不稳定 / 已终止。
Color projectLiveStatusColor(ProjectLiveStatus status, AppPalette palette) {
  return switch (status) {
    ProjectLiveStatus.running => palette.running,
    ProjectLiveStatus.success => palette.success,
    ProjectLiveStatus.failure => palette.danger,
    ProjectLiveStatus.unstable => palette.warning,
    ProjectLiveStatus.aborted => palette.muted,
    ProjectLiveStatus.idle => palette.info,
  };
}

/// 带发版状态的项目图标（侧栏项目树 / 顶部工程标签共用）。
///
/// - 本应用里这个项目正在发版 → 用 running 色并做呼吸动效
/// - 已出结果 → 成功绿 / 失败红 / 不稳定黄 / 终止灰
/// - 本应用没在跑（没开 run tab）→ 退回 [fallbackColor]；此时若 Jenkins 自带的
///   [jenkinsColor] 是 `*_anime`（别处触发的构建在跑），同样给动效
class ProjectStatusIcon extends ConsumerWidget {
  const ProjectStatusIcon({
    super.key,
    required this.accountId,
    required this.projectFullName,
    required this.icon,
    required this.size,
    required this.fallbackColor,
    this.jenkinsColor,
  });

  /// 为 null 表示拿不到账号（无法定位 run tab），只按 [fallbackColor] 静态显示。
  final String? accountId;
  final String? projectFullName;
  final IconData icon;
  final double size;
  final Color fallbackColor;

  /// Jenkins 节点的 `color` 字段，仅用于判断 `*_anime`。
  final String? jenkinsColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final id = accountId;
    final fullName = projectFullName;
    final live = (id == null || fullName == null || fullName.isEmpty)
        ? ProjectLiveStatus.idle
        : ref.watch(
            projectLiveStatusProvider((accountId: id, fullName: fullName)),
          );
    final color = live == ProjectLiveStatus.idle
        ? fallbackColor
        : projectLiveStatusColor(live, palette);
    final building =
        live == ProjectLiveStatus.running ||
        (live == ProjectLiveStatus.idle &&
            (jenkinsColor ?? '').endsWith('_anime'));
    final iconWidget = Icon(icon, size: size, color: color);
    return building ? BuildingPulse(child: iconWidget) : iconWidget;
  }
}
