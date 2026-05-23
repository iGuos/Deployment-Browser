import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../../jenkins/domain/jenkins_node.dart';
import '../../jenkins/domain/jenkins_tree_transform.dart';
import '../../settings/data/jenkins_config_repository.dart';
import '../application/jenkins_sidebar_favorites_provider.dart';
import '../application/jenkins_sidebar_tree_mode_provider.dart';
import '../application/workspace_controller.dart';
import '../domain/workspace_tab.dart';

/// 桌面 / 平板侧边栏：项目树 + 搜索框 + 顶部标题。
class WorkspaceSidebar extends ConsumerStatefulWidget {
  const WorkspaceSidebar({super.key});

  @override
  ConsumerState<WorkspaceSidebar> createState() => _WorkspaceSidebarState();
}

class _WorkspaceSidebarState extends ConsumerState<WorkspaceSidebar> {
  final TextEditingController _searchCtrl = TextEditingController();
  final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    // 单次 watch，避免对 workspace 注册多个 select 监听，减轻异步返回晚于 dispose 时的 defunct 断言。
    final ws = ref.watch(workspaceProvider);
    final accountId = ws.activeAccountId;
    final treeMode = ref.watch(jenkinsSidebarTreeModeProvider);
    final config = ref.watch(jenkinsConfigProvider).value;
    final treeAsync = accountId == null
        ? const AsyncValue<List<JenkinsNode>>.data([])
        : ref.watch(jenkinsTreeForAccountProvider(accountId));
    final favoritesOrder =
        accountId == null ? const <String>[] : ref.watch(jenkinsSidebarFavoritesProvider(accountId));
    final favoriteFullNames = favoritesOrder.toSet();

    final mobile = context.isMobile;

    late final Set<String> sidebarHighlightFullNames;
    late final Set<String> mobileToggleOpenFullNames;
    if (mobile) {
      final tabs = accountId == null
          ? const <WorkspaceTab>[]
          : (ws.byAccount[accountId]?.tabs ?? const <WorkspaceTab>[]);
      mobileToggleOpenFullNames = tabs
          .where((t) => t.kind == WorkspaceTabKind.project)
          .map((t) => t.projectFullName)
          .whereType<String>()
          .toSet();
      sidebarHighlightFullNames = mobileToggleOpenFullNames;
    } else {
      mobileToggleOpenFullNames = const <String>{};
      final tab = ws.active?.activeTab;
      final path =
          tab != null && tab.kind == WorkspaceTabKind.project ? tab.projectFullName : null;
      sidebarHighlightFullNames = {?path};
    }

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(right: BorderSide(color: palette.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: l10n.sidebarTitle,
            subtitle: config?.displayHost,
            treeMode: treeMode,
            onTreeMode: (m) => ref.read(jenkinsSidebarTreeModeProvider.notifier).setMode(m),
            onRefresh: () {
              final id = ref.read(workspaceProvider).activeAccountId;
              if (id != null) ref.read(jenkinsTreeReloadSignalProvider.notifier).bump(id);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Builder(
              builder: (ctx) {
                final mobile = ctx.isMobile;
                return TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: mobile ? 15 : 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.sidebarSearchHint,
                    hintStyle: mobile
                        ? TextStyle(
                            fontSize: 14.5,
                            color: Theme.of(ctx).hintColor,
                          )
                        : null,
                    prefixIcon: Icon(Icons.search_rounded, size: mobile ? 18 : 16),
                    prefixIconConstraints: BoxConstraints.tightFor(
                      width: mobile ? 36 : 32,
                      height: mobile ? 36 : 32,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: mobile ? 10 : 8,
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, color: palette.borderSubtle),
          Expanded(
            child: treeAsync.when(
              // 依赖变更重新拉树（reload）或 invalidate（refresh）时都不要沿用旧数据秒开。
              skipLoadingOnReload: false,
              skipLoadingOnRefresh: false,
              data: (tree) {
                final favEmpty = treeMode == JenkinsSidebarTreeMode.favorites &&
                    favoritesOrder.isEmpty &&
                    _searchCtrl.text.trim().isEmpty;
                if (favEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        l10n.sidebarFavoritesEmpty,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.muted, fontSize: 12, height: 1.45),
                      ),
                    ),
                  );
                }
                final roots = _filter(
                  transformJenkinsSidebarTree(
                    tree,
                    treeMode,
                    orderedFavoriteFullNames: favoritesOrder,
                  ),
                  _searchCtrl.text.trim().toLowerCase(),
                );
                return _buildSidebarTreeSection(
                  accountId,
                  treeMode,
                  roots,
                  favoriteFullNames,
                  mobile: mobile,
                  sidebarHighlightFullNames: sidebarHighlightFullNames,
                  mobileToggleOpenFullNames: mobileToggleOpenFullNames,
                );
              },
              error: (e, _) => _ErrorState(message: e.toString(), onRetry: () {
                final id = ref.read(workspaceProvider).activeAccountId;
                if (id != null) ref.read(jenkinsTreeReloadSignalProvider.notifier).bump(id);
              }),
              loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        ],
      ),
    );
  }

  List<JenkinsNode> _filter(List<JenkinsNode> input, String q) {
    if (q.isEmpty) return input;
    List<JenkinsNode> recurse(List<JenkinsNode> nodes) {
      final out = <JenkinsNode>[];
      for (final n in nodes) {
        if (n.children.isEmpty) {
          if (n.name.toLowerCase().contains(q) || n.fullName.toLowerCase().contains(q)) {
            out.add(n);
          }
        } else {
          final filteredChildren = recurse(n.children);
          if (filteredChildren.isNotEmpty || n.name.toLowerCase().contains(q)) {
            out.add(n.copyWith(children: filteredChildren));
          }
        }
      }
      return out;
    }

    return recurse(input);
  }

  Widget _buildSidebarTreeSection(
    String? accountId,
    JenkinsSidebarTreeMode treeMode,
    List<JenkinsNode> roots,
    Set<String> favoriteFullNames, {
    required bool mobile,
    required Set<String> sidebarHighlightFullNames,
    required Set<String> mobileToggleOpenFullNames,
  }) {
    final scrollBase = accountId != null
        ? 'jenkins_sidebar_tree_${treeMode.name}_$accountId'
        : 'jenkins_sidebar_tree_${treeMode.name}';

    final scrollSuffix = switch (treeMode) {
      JenkinsSidebarTreeMode.flat => '_flat',
      JenkinsSidebarTreeMode.favorites => '_favorites',
      JenkinsSidebarTreeMode.hierarchical => '_nested',
    };
    final scrollKey = accountId == null
        ? null
        : PageStorageKey<String>('$scrollBase$scrollSuffix');

    // 仅在「收藏」模式启用拖拽换序：顺序本来就是本地持久化的，且全部为顶级
    // 平铺节点（无 folder/multibranch 子层），ReorderableListView 用起来最直接。
    final searching = _searchCtrl.text.trim().isNotEmpty;
    final reorderEnabled = !searching &&
        treeMode == JenkinsSidebarTreeMode.favorites &&
        accountId != null;

    return _TreeBody(
      scrollStorageKey: scrollKey,
      nodes: roots,
      expanded: _expanded,
      favoriteFullNames: favoriteFullNames,
      accountId: accountId,
      onToggleFavorite: accountId == null
          ? null
          : (fullName) => ref.read(jenkinsSidebarFavoritesProvider(accountId).notifier).toggle(fullName),
      onReorder: reorderEnabled
          ? (from, to) {
              // ReorderableListView 在以下两种情况也会触发但视觉无变化，直接短路。
              if (to == from || to == from + 1) return;
              if (from < 0 || from >= roots.length) return;
              final fromName = roots[from].fullName;
              // ReorderableListView 语义：to 是"插入到原列表该索引前"；
              // to == length 表示拖到最末——传 null 让 notifier 落到 state 末尾。
              final beforeName = to < roots.length ? roots[to].fullName : null;
              ref
                  .read(jenkinsSidebarFavoritesProvider(accountId).notifier)
                  .reorderByFullName(fromName, beforeFullName: beforeName);
            }
          : null,
      onToggle: (key) => setState(() {
        if (!_expanded.add(key)) _expanded.remove(key);
      }),
      onJobRowActivate: (node) {
        final ws = ref.read(workspaceProvider);
        final aid = ws.activeAccountId;
        if (aid == null) return;
        final tab = WorkspaceTab.project(
          fullName: node.fullName,
          displayName: node.name,
          multibranch: node.kind == JenkinsNodeKind.multibranch,
        );
        final notifier = ref.read(workspaceProvider.notifier);
        if (!mobile) {
          notifier.openTab(tab);
          return;
        }
        final alreadyOpen = ws.byAccount[aid]?.tabs.any((t) => t.id == tab.id) ?? false;
        if (alreadyOpen) {
          notifier.closeTabForAccount(aid, tab.id);
        } else {
          notifier.openTab(tab);
        }
      },
      forceExpandAll: _searchCtrl.text.trim().isNotEmpty,
      sidebarHighlightFullNames: sidebarHighlightFullNames,
      mobileToggleOpenFullNames: mobileToggleOpenFullNames,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.subtitle,
    required this.treeMode,
    required this.onTreeMode,
    required this.onRefresh,
  });

  final String title;
  final String? subtitle;
  final JenkinsSidebarTreeMode treeMode;
  final ValueChanged<JenkinsSidebarTreeMode> onTreeMode;
  final VoidCallback onRefresh;

  static String _modeLabel(AppL10n l10n, JenkinsSidebarTreeMode m) => switch (m) {
        JenkinsSidebarTreeMode.hierarchical => l10n.sidebarTreeLayoutHierarchical,
        JenkinsSidebarTreeMode.flat => l10n.sidebarTreeLayoutFlat,
        JenkinsSidebarTreeMode.favorites => l10n.sidebarTreeLayoutFavorites,
      };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 2, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    letterSpacing: 0.4,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          PopupMenuButton<JenkinsSidebarTreeMode>(
            tooltip: l10n.sidebarTreeLayoutTooltip,
            padding: EdgeInsets.zero,
            onSelected: onTreeMode,
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem<JenkinsSidebarTreeMode>(
                value: JenkinsSidebarTreeMode.hierarchical,
                checked: treeMode == JenkinsSidebarTreeMode.hierarchical,
                child: Text(_modeLabel(l10n, JenkinsSidebarTreeMode.hierarchical)),
              ),
              CheckedPopupMenuItem<JenkinsSidebarTreeMode>(
                value: JenkinsSidebarTreeMode.flat,
                checked: treeMode == JenkinsSidebarTreeMode.flat,
                child: Text(_modeLabel(l10n, JenkinsSidebarTreeMode.flat)),
              ),
              CheckedPopupMenuItem<JenkinsSidebarTreeMode>(
                value: JenkinsSidebarTreeMode.favorites,
                checked: treeMode == JenkinsSidebarTreeMode.favorites,
                child: Text(_modeLabel(l10n, JenkinsSidebarTreeMode.favorites)),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.view_list_rounded, size: 18, color: palette.muted),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            tooltip: l10n.commonRefresh,
            onPressed: onRefresh,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          ),
        ],
      ),
    );
  }
}

IconData _sidebarJenkinsKindIcon(JenkinsNodeKind kind) {
  switch (kind) {
    case JenkinsNodeKind.folder:
      return Icons.folder_rounded;
    case JenkinsNodeKind.multibranch:
      return Icons.account_tree_rounded;
    case JenkinsNodeKind.job:
      return Icons.rocket_launch_rounded;
    case JenkinsNodeKind.unknown:
      return Icons.help_outline_rounded;
  }
}

Color _sidebarJenkinsNodeIconColor(JenkinsNode node, AppPalette palette) {
  if (node.isFolder) return palette.warning;
  final color = node.color ?? '';
  if (color.contains('blue')) return palette.success;
  if (color.contains('red')) return palette.danger;
  if (color.contains('yellow')) return palette.warning;
  if (color.contains('aborted') || color.contains('grey') || color.contains('disabled')) {
    return palette.muted;
  }
  return palette.info;
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 28, color: palette.danger),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(AppL10n.of(context).commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

class _TreeBody extends StatelessWidget {
  const _TreeBody({
    this.scrollStorageKey,
    required this.nodes,
    required this.expanded,
    required this.favoriteFullNames,
    required this.accountId,
    required this.onToggleFavorite,
    required this.onToggle,
    required this.onJobRowActivate,
    required this.forceExpandAll,
    required this.sidebarHighlightFullNames,
    required this.mobileToggleOpenFullNames,
    this.onReorder,
  });

  /// 按账号（及树布局模式）区分，切换一级 Jenkins 标签回来时保留项目树滚动位置。
  final PageStorageKey<String>? scrollStorageKey;
  final List<JenkinsNode> nodes;
  final Set<String> expanded;
  final Set<String> favoriteFullNames;
  final String? accountId;
  final Future<void> Function(String fullName)? onToggleFavorite;
  final void Function(String key) onToggle;
  /// 移动端：打开或切换关闭标签；桌面端：仅打开/激活标签。
  final void Function(JenkinsNode node) onJobRowActivate;
  final bool forceExpandAll;

  /// 侧栏行高亮：移动端为已打开的全部工程；桌面端仅为当前激活 tab。
  final Set<String> sidebarHighlightFullNames;

  /// 仅移动端用于「再点关闭」判断；桌面端恒为空集。
  final Set<String> mobileToggleOpenFullNames;

  /// 非空表示启用拖拽换序（当前仅收藏模式传值）。
  final void Function(int oldIndex, int newIndex)? onReorder;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      final palette = context.palette;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            AppL10n.of(context).commonEmpty,
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ),
      );
    }
    if (onReorder != null) {
      return ReorderableListView.builder(
        // 关掉默认的右侧拖拽手柄：那个图标会和收藏星按钮挤在一起；
        // 用 ReorderableDragStartListener 把整行作为拖拽源，行内点击行为不受影响
        // （drag 与 tap 在 gesture arena 里按移动距离自然区分）。
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: nodes.length,
        itemBuilder: (ctx, i) {
          final node = nodes[i];
          return ReorderableDragStartListener(
            key: ValueKey('fav:${node.fullName}'),
            index: i,
            child: _buildNode(ctx, node, depth: 0),
          );
        },
        onReorder: onReorder!,
      );
    }
    return ListView(
      key: scrollStorageKey,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final n in nodes) _buildNode(context, n, depth: 0),
      ],
    );
  }

  Widget _buildNode(BuildContext context, JenkinsNode node, {required int depth}) {
    final isOpen = forceExpandAll || expanded.contains(node.fullName);
    final isSelected = sidebarHighlightFullNames.contains(node.fullName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NodeRow(
          node: node,
          depth: depth,
          expanded: isOpen,
          isSelected: isSelected,
          showFavorite:
              accountId != null && onToggleFavorite != null && node.canFavoriteInSidebar,
          isFavorite: favoriteFullNames.contains(node.fullName),
          onFavoriteTap: onToggleFavorite == null
              ? null
              : () => onToggleFavorite!(node.fullName),
          onTap: () {
            final expandable = node.children.isNotEmpty &&
                (node.kind == JenkinsNodeKind.folder ||
                    node.kind == JenkinsNodeKind.multibranch);
            // 仅移动端：构建页已打开该工程时再点行 → 关闭标签（桌面不走此分支）。
            if (mobileToggleOpenFullNames.contains(node.fullName)) {
              onJobRowActivate(node);
              return;
            }
            if (expandable) {
              onToggle(node.fullName);
              return;
            }
            if (node.kind == JenkinsNodeKind.job ||
                node.kind == JenkinsNodeKind.multibranch ||
                node.kind == JenkinsNodeKind.unknown) {
              onJobRowActivate(node);
              return;
            }
            if (node.kind == JenkinsNodeKind.folder) {
              onToggle(node.fullName);
            }
          },
        ),
        if (isOpen && node.children.isNotEmpty)
          ...node.children.map((c) => _buildNode(context, c, depth: depth + 1)),
      ],
    );
  }
}

class _NodeRow extends StatefulWidget {
  const _NodeRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.isSelected,
    required this.onTap,
    required this.showFavorite,
    required this.isFavorite,
    required this.onFavoriteTap,
  });

  final JenkinsNode node;
  final int depth;
  final bool expanded;
  final bool isSelected;
  final VoidCallback onTap;
  final bool showFavorite;
  final bool isFavorite;
  final VoidCallback? onFavoriteTap;

  @override
  State<_NodeRow> createState() => _NodeRowState();
}

class _NodeRowState extends State<_NodeRow> {
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
    final mobile = context.isMobile;
    final node = widget.node;
    final showChevron =
        node.children.isNotEmpty && (node.kind == JenkinsNodeKind.folder || node.kind == JenkinsNodeKind.multibranch);
    final iconColor = _sidebarJenkinsNodeIconColor(node, palette);

    final selected = widget.isSelected;
    final rowH = mobile ? 36.0 : 28.0;
    final depthStep = mobile ? 16.0 : 14.0;
    final chevronW = mobile ? 18.0 : 14.0;
    final chevronIcon = mobile ? 17.0 : 14.0;
    final kindIcon = mobile ? 17.0 : 14.0;
    final nameSize = mobile ? 14.5 : 12.5;

    Color rowBg = Colors.transparent;
    if (selected) {
      rowBg = palette.accent.withValues(alpha: mobile ? 0.22 : 0.14);
      if (_hovered) {
        rowBg = palette.accent.withValues(alpha: mobile ? 0.30 : 0.20);
      }
    } else if (_hovered) {
      rowBg = palette.hoverOverlay;
    }

    return MouseRegion(
      onEnter: (_) => _setHoveredDeferred(true),
      onExit: (_) => _setHoveredDeferred(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: rowH,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * depthStep, right: 8),
          decoration: BoxDecoration(
            color: rowBg,
            border: selected && mobile
                ? Border(left: BorderSide(color: palette.accent, width: 3))
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: chevronW,
                child: showChevron
                    ? Icon(
                        widget.expanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                        size: chevronIcon,
                        color: palette.muted,
                      )
                    : null,
              ),
              SizedBox(width: mobile ? 6 : 4),
              Icon(_sidebarJenkinsKindIcon(node.kind), size: kindIcon, color: iconColor),
              SizedBox(width: mobile ? 10 : 8),
              Expanded(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: nameSize,
                    height: mobile ? 1.25 : null,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.showFavorite && widget.onFavoriteTap != null)
                Tooltip(
                  message: widget.isFavorite
                      ? AppL10n.of(context).sidebarUnfavoriteTooltip
                      : AppL10n.of(context).sidebarFavoriteTooltip,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints.tightFor(
                        width: mobile ? 30 : 26,
                        height: mobile ? 30 : 26,
                      ),
                      iconSize: mobile ? 17 : 15,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        widget.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: widget.isFavorite ? palette.warning : palette.muted,
                      ),
                      onPressed: widget.onFavoriteTap,
                    ),
                  ),
                ),
              if (!node.isFolder && node.lastBuildResult != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _ResultDot(result: node.lastBuildResult!, palette: palette),
                ),
            ],
          ),
        ),
      ),
    );
  }

}

class _ResultDot extends StatelessWidget {
  const _ResultDot({required this.result, required this.palette});

  final String result;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.toUpperCase()) {
      'SUCCESS' => palette.success,
      'FAILURE' => palette.danger,
      'UNSTABLE' => palette.warning,
      _ => palette.muted,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
