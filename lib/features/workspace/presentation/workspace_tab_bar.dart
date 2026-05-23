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
/// - 没有 tab 时整条栏依然占位，作为内容区与项目树头部之间的视觉分隔；
/// - 右侧固定一组工具：← / → 滚动 + ⌄ 批量关闭菜单（关闭当前/其他/全部）。
class WorkspaceTabBar extends ConsumerStatefulWidget {
  const WorkspaceTabBar({super.key, required this.accountId});

  /// 本地 Jenkins 账号 id（对应 [WorkspaceState.byAccount] 的键）。
  final String accountId;

  @override
  ConsumerState<WorkspaceTabBar> createState() => _WorkspaceTabBarState();
}

class _WorkspaceTabBarState extends ConsumerState<WorkspaceTabBar> {
  final ScrollController _scroll = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_recomputeBounds);
  }

  @override
  void dispose() {
    _scroll.removeListener(_recomputeBounds);
    _scroll.dispose();
    super.dispose();
  }

  void _recomputeBounds() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final l = _scroll.offset > pos.minScrollExtent + 0.5;
    final r = _scroll.offset < pos.maxScrollExtent - 0.5;
    if (l != _canLeft || r != _canRight) {
      setState(() {
        _canLeft = l;
        _canRight = r;
      });
    }
  }

  void _scrollBy(double delta) {
    if (!_scroll.hasClients) return;
    final next = (_scroll.offset + delta).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ws = ref.watch(workspaceProvider);
    final accountWs = ws.byAccount[widget.accountId];
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
      child: Row(
        children: [
          _BarIconButton(
            icon: Icons.chevron_left_rounded,
            tooltip: '向左滚动',
            enabled: _canLeft,
            onPressed: () => _scrollBy(-220),
          ),
          Expanded(
            child: NotificationListener<ScrollMetricsNotification>(
              // 内容尺寸 / 视口变化时（添加/关闭 tab、首次布局）由这里兜底，
              // 因为 ScrollController.addListener 只在滚动位置变化时触发。
              onNotification: (_) {
                _recomputeBounds();
                return false;
              },
              child: HorizontalScrollStrip(
                controller: _scroll,
                itemCount: tabs.length,
                itemBuilder: (ctx, i) {
                  final tab = tabs[i];
                  final active = tab.id == tabActiveId;
                  return _DraggableTab(
                    key: ValueKey(tab.id),
                    index: i,
                    tab: tab,
                    active: active,
                    onActivate: () => notifier.activateTabForAccount(
                      widget.accountId,
                      tab.id,
                    ),
                    onClose: () => notifier.closeTabForAccount(
                      widget.accountId,
                      tab.id,
                    ),
                    onReorder: (from, to) => notifier.reorderTabForAccount(
                      widget.accountId,
                      from,
                      to,
                    ),
                  );
                },
              ),
            ),
          ),
          _BarIconButton(
            icon: Icons.chevron_right_rounded,
            tooltip: '向右滚动',
            enabled: _canRight,
            onPressed: () => _scrollBy(220),
          ),
          _CloseMenuButton(
            enabled: tabs.isNotEmpty,
            hasActive: tabActiveId.isNotEmpty,
            hasOthers: tabs.length > 1,
            onCloseCurrent: () => tabActiveId.isEmpty
                ? null
                : notifier.closeTabForAccount(widget.accountId, tabActiveId),
            onCloseOthers: () =>
                tabActiveId.isEmpty ? null : notifier.closeOthers(tabActiveId),
            onCloseAll: notifier.closeAll,
          ),
        ],
      ),
    );
  }
}

/// 紧凑型工具按钮（高度匹配 tab bar）。
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: SizedBox(
        width: 32,
        child: IconButton(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon, size: 18),
          color: palette.muted,
          disabledColor: palette.muted.withValues(alpha: 0.35),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

enum _CloseMenuAction { current, others, all }

class _CloseMenuButton extends StatelessWidget {
  const _CloseMenuButton({
    required this.enabled,
    required this.hasActive,
    required this.hasOthers,
    required this.onCloseCurrent,
    required this.onCloseOthers,
    required this.onCloseAll,
  });

  final bool enabled;
  final bool hasActive;
  final bool hasOthers;
  final VoidCallback onCloseCurrent;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseAll;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: '更多',
      waitDuration: const Duration(milliseconds: 300),
      child: PopupMenuButton<_CloseMenuAction>(
        enabled: enabled,
        tooltip: '',
        position: PopupMenuPosition.under,
        icon: Icon(Icons.expand_more_rounded, size: 18, color: palette.muted),
        padding: EdgeInsets.zero,
        onSelected: (action) {
          switch (action) {
            case _CloseMenuAction.current:
              onCloseCurrent();
            case _CloseMenuAction.others:
              onCloseOthers();
            case _CloseMenuAction.all:
              onCloseAll();
          }
        },
        itemBuilder: (ctx) => [
          PopupMenuItem(
            enabled: hasActive,
            value: _CloseMenuAction.current,
            child: const _CloseMenuRow(
              icon: Icons.close_rounded,
              label: '关闭当前',
            ),
          ),
          PopupMenuItem(
            enabled: hasOthers,
            value: _CloseMenuAction.others,
            child: const _CloseMenuRow(
              icon: Icons.tab_unselected_rounded,
              label: '关闭其他',
            ),
          ),
          PopupMenuItem(
            value: _CloseMenuAction.all,
            child: const _CloseMenuRow(
              icon: Icons.delete_sweep_rounded,
              label: '关闭全部',
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseMenuRow extends StatelessWidget {
  const _CloseMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: palette.muted),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: palette.text, fontSize: 13)),
      ],
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
