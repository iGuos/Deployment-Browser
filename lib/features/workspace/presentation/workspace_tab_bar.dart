import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/horizontal_tab_scroll.dart';
import '../application/workspace_controller.dart';
import '../domain/workspace_tab.dart';

/// 顶部 chrome-style 多标签栏。
///
/// - 横向滚动；标签 + 关闭按钮；
/// - 活跃标签使用 `surface` 背景 + 顶部强调色边；
/// - 没有 tab 时整条栏依然占位，作为内容区与项目树头部之间的视觉分隔。
class WorkspaceTabBar extends ConsumerWidget {
  const WorkspaceTabBar({super.key, required this.accountId});

  /// 本地 Jenkins 账号 id（对应 [WorkspaceState.byAccount] 的键）。
  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final ws = ref.watch(workspaceProvider);
    final accountWs = ws.byAccount[accountId];
    final tabs = accountWs?.tabs ?? const <WorkspaceTab>[];
    final tabActiveId = accountWs?.activeId ?? '';
    final notifier = ref.read(workspaceProvider.notifier);
    final barHeight = context.isMobile ? 32.0 : 36.0;

    return Container(
      height: barHeight,
      decoration: BoxDecoration(
        color: palette.chromeBar,
        border: Border(
          bottom: BorderSide(color: palette.borderSubtle, width: 0.8),
        ),
      ),
      child: HorizontalScrollStrip(
        itemCount: tabs.length,
        itemBuilder: (ctx, i) {
          final tab = tabs[i];
          final active = tab.id == tabActiveId;
          return _DraggableTab(
            key: ValueKey(tab.id),
            index: i,
            tab: tab,
            active: active,
            onActivate: () => notifier.activateTabForAccount(accountId, tab.id),
            onClose: () => notifier.closeTabForAccount(accountId, tab.id),
            onReorder: (from, to) =>
                notifier.reorderTabForAccount(accountId, from, to),
          );
        },
      ),
    );
  }
}

/// 把 [_TabChip] 包一层 [Draggable] + [DragTarget]，实现 Chrome 风格的同栏拖拽换序。
///
/// 设计要点：
/// - 拖拽载荷是 **源 index**；落点是 **目标 index**；交给上层做位移计算。
/// - 拖动中源 chip 半透明占位（避免列表突然缩短导致目标位置漂移）。
/// - 目标 chip 上根据相对方向画一条强调色竖线，告诉用户最终插入位置。
class _DraggableTab extends StatelessWidget {
  const _DraggableTab({
    super.key,
    required this.index,
    required this.tab,
    required this.active,
    required this.onActivate,
    required this.onClose,
    required this.onReorder,
  });

  final int index;
  final WorkspaceTab tab;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback onClose;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chip = _TabChip(
      tab: tab,
      active: active,
      onActivate: onActivate,
      onClose: onClose,
    );

    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => onReorder(d.data, index),
      builder: (ctx, candidate, _) {
        final from = candidate.isNotEmpty ? candidate.first : null;
        final showLeft = from != null && from > index;
        final showRight = from != null && from < index;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Draggable<int>(
              data: index,
              axis: Axis.horizontal,
              feedback: _DragFeedback(tab: tab, active: active),
              childWhenDragging: Opacity(opacity: 0.3, child: chip),
              child: chip,
            ),
            if (showLeft)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _DropIndicator(color: palette.accent),
              ),
            if (showRight)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _DropIndicator(color: palette.accent),
              ),
          ],
        );
      },
    );
  }
}

class _DropIndicator extends StatelessWidget {
  const _DropIndicator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 2, color: color);
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.tab, required this.active});

  final WorkspaceTab tab;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.9,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border.all(color: palette.accent.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SizedBox(
              height: 32,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      tab.kind == WorkspaceTabKind.settings
                          ? Icons.settings_rounded
                          : Icons.rocket_launch_rounded,
                      size: 14,
                      color: tab.kind == WorkspaceTabKind.settings
                          ? palette.muted
                          : palette.info,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: palette.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onActivate,
    this.onClose,
  });

  final WorkspaceTab tab;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback? onClose;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hovered = false;

  void _setHoveredDeferred(bool v) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hovered == v) return;
      setState(() => _hovered = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tab = widget.tab;
    final active = widget.active;

    final bg = active
        ? palette.surface
        : _hovered
            ? palette.tabInactive.withValues(alpha: 0.85)
            : palette.tabInactive;

    final accentTop = active
        ? Container(
            height: 2,
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          )
        : const SizedBox(height: 2);

    return MouseRegion(
      onEnter: (_) => _setHoveredDeferred(true),
      onExit: (_) => _setHoveredDeferred(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivate,
        child: Container(
          margin: const EdgeInsets.only(right: 1),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              right: BorderSide(color: palette.borderSubtle, width: 0.6),
            ),
          ),
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              accentTop,
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      _kindIcon(tab.kind, palette),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tab.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                            color: active ? palette.text : palette.muted,
                          ),
                        ),
                      ),
                      if (widget.onClose != null) ...[
                        const SizedBox(width: 6),
                        _CloseButton(
                          visible: active || _hovered,
                          onPressed: widget.onClose!,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kindIcon(WorkspaceTabKind kind, AppPalette palette) {
    switch (kind) {
      case WorkspaceTabKind.settings:
        return Icon(Icons.settings_rounded, size: 14, color: palette.muted);
      case WorkspaceTabKind.project:
        return Icon(Icons.rocket_launch_rounded, size: 14, color: palette.info);
    }
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  void _setHoveredDeferred(bool v) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hovered == v) return;
      setState(() => _hovered = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: MouseRegion(
        onEnter: (_) => _setHoveredDeferred(true),
        onExit: (_) => _setHoveredDeferred(false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: _hovered ? palette.hoverOverlay : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 12,
              color: palette.muted,
            ),
          ),
        ),
      ),
    );
  }
}
