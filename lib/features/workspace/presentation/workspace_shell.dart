import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/http/jenkins_http_client.dart';
import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../../jenkins/presentation/project_page.dart';
import '../../settings/application/network_proxy_state_provider.dart';
import '../../settings/data/jenkins_accounts_repository.dart';
import '../../settings/presentation/accounts_page.dart';
import '../../settings/presentation/app_settings_dialog.dart';
import '../../settings/presentation/proxy_window_io.dart';
import '../../settings/presentation/settings_page.dart';
import '../../../plug/network_proxy/application/network_proxy_certificate_prompt_controller.dart';
import '../application/workspace_controller.dart';
import '../domain/workspace_tab.dart';
import 'workspace_account_bar.dart';
import 'workspace_sidebar.dart';
import 'workspace_status_bar.dart';
import 'workspace_tab_bar.dart';

/// 供尚无 Job 标签时的空状态等子组件切换到移动端底部导航指定栏。
class _MobileWorkspaceNavActions extends InheritedWidget {
  const _MobileWorkspaceNavActions({
    required this.selectBottomNavIndex,
    required super.child,
  });

  final ValueSetter<int> selectBottomNavIndex;

  static _MobileWorkspaceNavActions? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_MobileWorkspaceNavActions>();
  }

  @override
  bool updateShouldNotify(covariant _MobileWorkspaceNavActions oldWidget) =>
      selectBottomNavIndex != oldWidget.selectBottomNavIndex;
}

int _workspacePrimaryIndex(WorkspaceState ws) {
  final opened = ws.openedAccountIds;
  final id = ws.activeAccountId;
  if (opened.isEmpty || id == null) return 0;
  final i = opened.indexOf(id);
  return i >= 0 ? i : 0;
}

/// 单个 Jenkins 账号下的二级 tab 内容（配合 [IndexedStack] 保留离屏页面状态）。
class WorkspaceTabBody extends ConsumerWidget {
  const WorkspaceTabBody({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(workspaceProvider);
    final accountWs = ws.byAccount[accountId];
    if (accountWs == null || accountWs.tabs.isEmpty) return const _NoTabState();
    final tabs = accountWs.tabs;

    final activeId = accountWs.activeId;
    var index = tabs.indexWhere((t) => t.id == activeId);
    if (index < 0) index = 0;

    // IndexedStack：切换二级 tab / 一级账号时离屏页面保持挂载，避免重复拉接口与丢表单状态；
    // 关闭 tab 后子树移除，且 controller 会 invalidate projectDetail，下次打开重新加载。
    return IndexedStack(
      index: index.clamp(0, tabs.length - 1),
      sizing: StackFit.expand,
      children: [
        for (final tab in tabs)
          KeyedSubtree(
            key: ValueKey('$accountId#${tab.id}'),
            child: switch (tab.kind) {
              WorkspaceTabKind.settings => const SettingsPage(),
              WorkspaceTabKind.project => ProjectPage(
                jenkinsAccountId: accountId,
                fullName: tab.projectFullName!,
                displayName: tab.title,
                multibranch: tab.projectKind == 'multibranch',
              ),
            },
          ),
      ],
    );
  }
}

class _WorkspaceAccountColumn extends ConsumerWidget {
  const _WorkspaceAccountColumn({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceTabBar(accountId: accountId),
        Expanded(child: WorkspaceTabBody(accountId: accountId)),
      ],
    );
  }
}

/// 整体主壳：桌面/平板使用 sidebar + 多 tab 工作区；移动使用 bottom nav + drawer。
class WorkspaceShell extends ConsumerWidget {
  const WorkspaceShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return context.isWide ? const _DesktopShell() : const _MobileShell();
  }
}

class _DesktopShell extends ConsumerStatefulWidget {
  const _DesktopShell();

  @override
  ConsumerState<_DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<_DesktopShell> {
  double _sidebarWidth = 260;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accountsAsync = ref.watch(jenkinsAccountsProvider);
    final ws = ref.watch(workspaceProvider);
    final hasConfiguredAccounts =
        accountsAsync.value?.accounts.isNotEmpty ?? false;
    final hasWorkspace = ws.hasOpenWorkspace;

    return Scaffold(
      backgroundColor: palette.bg,
      body: Column(
        children: [
          const _AppHeader(),
          // 最外层：账号 tab 栏（账号配置入口在 [_AppHeader] 主题图标左侧，此处不再重复）
          const WorkspaceAccountBar(allowManageAccountsButton: false),
          Expanded(
            child: hasWorkspace
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _sidebarWidth,
                        child: const WorkspaceSidebar(),
                      ),
                      _SidebarResizer(
                        onDelta: (dx) => setState(() {
                          _sidebarWidth = (_sidebarWidth + dx).clamp(
                            200.0,
                            480.0,
                          );
                        }),
                      ),
                      // 二级 tab + 内容按账号分栈，离屏不销毁，切换一级标签不切二级状态
                      Expanded(
                        child: IndexedStack(
                          index: _workspacePrimaryIndex(ws),
                          sizing: StackFit.expand,
                          children: [
                            for (final id in ws.openedAccountIds)
                              _WorkspaceAccountColumn(accountId: id),
                          ],
                        ),
                      ),
                    ],
                  )
                : hasConfiguredAccounts
                ? const _PickWorkspaceHint()
                : const _NoAccountState(),
          ),
          const WorkspaceStatusBar(),
        ],
      ),
    );
  }
}

class _SidebarResizer extends StatelessWidget {
  const _SidebarResizer({required this.onDelta});

  final void Function(double dx) onDelta;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        child: Container(
          width: 4,
          color: palette.bg,
          alignment: Alignment.center,
          child: Container(width: 1, color: palette.borderSubtle),
        ),
      ),
    );
  }
}

class _MobileShell extends ConsumerStatefulWidget {
  const _MobileShell();

  @override
  ConsumerState<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<_MobileShell> {
  static const _proxyCertificatePromptController =
      NetworkProxyCertificatePromptController();

  /// 底部导航：0 项目（左）、1 构建（中）、2 账户（右）；默认落在「构建」。
  int _navIndex = 1;
  bool _proxyCertificateDialogOpen = false;
  bool _proxyCertificatePolling = false;
  String? _lastProxyCertificatePromptKey;
  Timer? _proxyCertificateProbeTimer;

  void _selectBottomNav(int index) {
    setState(() => _navIndex = index);
  }

  static const int _mobileNavProjects = 0;
  static const int _mobileNavBuilds = 1;
  static const int _mobileNavAccounts = 2;

  @override
  void initState() {
    super.initState();
    ref.read(workspaceProvider.notifier).setMobileStripMirrorsAllAccounts(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_pollProxyCertificateStatus());
    });
    _proxyCertificateProbeTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_pollProxyCertificateStatus()),
    );
  }

  @override
  void dispose() {
    _proxyCertificateProbeTimer?.cancel();
    ref
        .read(workspaceProvider.notifier)
        .setMobileStripMirrorsAllAccounts(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final ws = ref.watch(workspaceProvider);
    _listenForProxyCertificateRequired(ws.activeAccountId);
    final palette = context.palette;
    final accountsAsync = ref.watch(jenkinsAccountsProvider);
    final hasConfiguredAccounts =
        accountsAsync.value?.accounts.isNotEmpty ?? false;
    final hasWorkspace = ws.hasOpenWorkspace;

    Widget body;
    switch (_navIndex) {
      case _mobileNavProjects:
        body = const WorkspaceSidebar();
        break;
      case _mobileNavBuilds:
        body = hasWorkspace
            ? IndexedStack(
                index: _workspacePrimaryIndex(ws),
                sizing: StackFit.expand,
                children: [
                  for (final id in ws.openedAccountIds)
                    _WorkspaceAccountColumn(accountId: id),
                ],
              )
            : hasConfiguredAccounts
            ? const _PickWorkspaceHint()
            : const _NoAccountState();
        break;
      case _mobileNavAccounts:
        // 移动端「账户」底栏：直接进入账号管理（增删、扫码、编辑连接等在列表内完成）。
        body = const AccountsManagerView(compactHeader: true);
        break;
      default:
        body = const SizedBox.shrink();
    }

    return _MobileWorkspaceNavActions(
      selectBottomNavIndex: _selectBottomNav,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_titleFor(_navIndex, l10n, ws.activeTab?.title)),
          actions: [
            IconButton(
              tooltip: l10n.settingsSectionProxy,
              icon: const Icon(Icons.lan_outlined, size: 22),
              onPressed: () => openAppProxySettings(context: context),
            ),
            IconButton(
              tooltip: l10n.settingsDialogTitle,
              icon: const Icon(Icons.settings_outlined, size: 22),
              onPressed: () => showAppSettingsDialog(context),
            ),
          ],
          bottom:
              (_navIndex == _mobileNavProjects || _navIndex == _mobileNavBuilds)
              ? PreferredSize(
                  preferredSize: Size.fromHeight(context.isMobile ? 42 : 48),
                  child: const WorkspaceAccountBar(
                    allowOpenWorkspace: false,
                    allowCloseWorkspaceStrip: false,
                    allowManageAccountsButton: false,
                  ),
                )
              : null,
        ),
        body: body,
        bottomNavigationBar: _MobileBottomNavBar(
          palette: palette,
          themeBrightness: Theme.of(context).brightness,
          selectedIndex: _navIndex,
          onSelect: _selectBottomNav,
          l10n: l10n,
        ),
      ),
    );
  }

  String _titleFor(int i, AppL10n l10n, String? activeTitle) => switch (i) {
    _mobileNavProjects => l10n.navProjects,
    _mobileNavBuilds => activeTitle ?? l10n.appTitle,
    _mobileNavAccounts => l10n.navAccounts,
    _ => l10n.appTitle,
  };

  void _listenForProxyCertificateRequired(String? accountId) {
    if (accountId == null) return;
    ref.listen<AsyncValue<List<Object?>>>(
      jenkinsTreeForAccountProvider(accountId).select(
        (value) => value.when(
          data: (_) => const AsyncValue.data(<Object?>[]),
          loading: () => const AsyncValue.loading(),
          error: (error, stackTrace) => AsyncValue.error(error, stackTrace),
        ),
      ),
      (previous, next) {
        next.whenOrNull(
          error: (error, _) => _showProxyCertificateDialogIfNeeded(error),
        );
      },
    );
  }

  void _showProxyCertificateDialogIfNeeded(Object error) {
    if (!mounted || _proxyCertificateDialogOpen) return;
    if (error is! JenkinsException) return;
    if (!error.proxyCertificateRequired) {
      if (ref.read(networkProxyStateProvider).shouldUseClientProxy) {
        appLogger.i('代理证书探测：Jenkins 网络失败后立即触发探测 message=${error.message}');
        unawaited(_pollProxyCertificateStatus(force: true));
      }
      return;
    }
    final installUrl = _proxyCertificateInstallUrl();
    if (installUrl == null) return;
    _showProxyCertificateInstallDialogIfNeeded(installUrl);
  }

  Future<void> _pollProxyCertificateStatus({bool force = false}) async {
    if (_proxyCertificatePolling || !mounted) return;
    final state = ref.read(networkProxyStateProvider);
    if (!_proxyCertificatePromptController.shouldProbe(state)) {
      appLogger.i(
        '代理证书探测：跳过，客户端代理未启用 role=${state.role.name} enabled=${state.client.enabled}',
      );
      return;
    }
    _proxyCertificatePolling = true;
    try {
      appLogger.i(
        '代理证书探测：开始 ${state.client.encrypted ? '加密' : '明文'} '
        '${state.client.host}:${state.client.port} force=$force',
      );
      final result = await _proxyCertificatePromptController.probe(state);
      appLogger.i(
        '代理证书探测：结果 reachable=${result.proxyReachable} '
        'required=${result.certificateRequired} trusted=${result.certificateTrusted} '
        'status=${result.status} url=${result.installUrl} error=${result.error}',
      );
      if (!mounted) return;
      if (_proxyCertificatePromptController.shouldPrompt(result)) {
        final installUrl = result.installUrl ?? _proxyCertificateInstallUrl();
        if (installUrl != null) {
          _showProxyCertificateInstallDialogIfNeeded(installUrl);
        }
      }
    } finally {
      _proxyCertificatePolling = false;
    }
  }

  void _showProxyCertificateInstallDialogIfNeeded(String installUrl) {
    if (!mounted || _proxyCertificateDialogOpen) return;
    final key = '$installUrl:${DateTime.now().millisecondsSinceEpoch ~/ 30000}';
    if (_lastProxyCertificatePromptKey == key) return;
    _lastProxyCertificatePromptKey = key;
    _proxyCertificateDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _proxyCertificateDialogOpen = false;
        return;
      }
      unawaited(_showProxyCertificateDialog(installUrl));
    });
  }

  String? _proxyCertificateInstallUrl() {
    return _proxyCertificatePromptController.installUrlFromState(
      ref.read(networkProxyStateProvider),
    );
  }

  Future<void> _showProxyCertificateDialog(String installUrl) async {
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要安装 HTTPS 解密证书'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '当前代理开启了 HTTPS 解密抓包，手机还没有安装或完全信任根证书，所以 Jenkins 请求会失败。',
              ),
              const SizedBox(height: 12),
              const Text('请用 Safari 打开下面地址下载并信任证书：'),
              const SizedBox(height: 8),
              SelectableText(
                installUrl,
                style: Theme.of(
                  dialogContext,
                ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              Text(
                '安装后进入「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任，再回到 App 重试。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(
                  launchUrl(
                    Uri.parse(installUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                );
              },
              child: const Text('打开安装页'),
            ),
          ],
        ),
      );
    } finally {
      _proxyCertificateDialogOpen = false;
    }
  }
}

/// 自绘底栏（替代 [NavigationBar]）：Material 3 导航栏内部含 [SafeArea] 与固定布局，
/// 在部分机型上 `height` / `labelPadding` 等参数几乎不起作用，导致「改代码无效」。
class _MobileBottomNavBar extends StatelessWidget {
  const _MobileBottomNavBar({
    required this.palette,
    required this.themeBrightness,
    required this.selectedIndex,
    required this.onSelect,
    required this.l10n,
  });

  final AppPalette palette;
  final Brightness themeBrightness;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    final isDark = themeBrightness == Brightness.dark;
    final viewBottom = MediaQuery.viewPaddingOf(context).bottom;
    final homeGap = viewBottom > 0 ? math.max(3.0, viewBottom * 0.14) : 0.0;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        border: Border(
          top: BorderSide(
            color: palette.border.withValues(alpha: isDark ? 0.85 : 0.45),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.06),
            offset: const Offset(0, -4),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: _MobileNavItem(
                    palette: palette,
                    selected:
                        selectedIndex == _MobileShellState._mobileNavProjects,
                    icon: Icons.account_tree_rounded,
                    label: l10n.navProjects,
                    onTap: () => onSelect(_MobileShellState._mobileNavProjects),
                  ),
                ),
                Expanded(
                  child: _MobileNavItem(
                    palette: palette,
                    selected:
                        selectedIndex == _MobileShellState._mobileNavBuilds,
                    icon: Icons.dashboard_rounded,
                    label: l10n.navBuilds,
                    onTap: () => onSelect(_MobileShellState._mobileNavBuilds),
                  ),
                ),
                Expanded(
                  child: _MobileNavItem(
                    palette: palette,
                    selected:
                        selectedIndex == _MobileShellState._mobileNavAccounts,
                    icon: Icons.manage_accounts_rounded,
                    label: l10n.navAccounts,
                    onTap: () => onSelect(_MobileShellState._mobileNavAccounts),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: homeGap),
        ],
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({
    required this.palette,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final AppPalette palette;
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? palette.accent : palette.muted;

    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: palette.accent.withValues(alpha: 0.14),
            highlightColor: palette.accent.withValues(alpha: 0.06),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? palette.accent.withValues(alpha: 0.22)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(icon, size: 24, color: fg),
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppHeader extends ConsumerWidget {
  const _AppHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(Icons.rocket_launch_rounded, color: palette.accent, size: 18),
          const SizedBox(width: 8),
          Text(
            l10n.appTitle,
            style: TextStyle(
              color: palette.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          Tooltip(
            message: l10n.accountsManage,
            child: IconButton(
              icon: const Icon(Icons.manage_accounts_rounded, size: 20),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              splashRadius: 18,
              onPressed: () => showAccountsManagerDialog(context),
            ),
          ),
          Tooltip(
            message: l10n.settingsSectionProxy,
            child: IconButton(
              icon: const Icon(Icons.lan_outlined, size: 20),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              splashRadius: 18,
              onPressed: () => openAppProxySettings(context: context),
            ),
          ),
          Tooltip(
            message: l10n.settingsDialogTitle,
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 20),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              splashRadius: 18,
              onPressed: () => showAppSettingsDialog(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 已配置 Jenkins，但尚未通过顶级栏「+」打开任何工作区标签。
class _PickWorkspaceHint extends ConsumerWidget {
  const _PickWorkspaceHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Icon(
                Icons.add_circle_outline_rounded,
                size: 38,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.workspaceEmptyPrimaryTabsTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.workspaceEmptyPrimaryTabsSubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.muted,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.workspacePickerTitle),
              onPressed: () => showJenkinsWorkspacePicker(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoAccountState extends ConsumerWidget {
  const _NoAccountState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Icon(
                Icons.manage_accounts_outlined,
                size: 38,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.accountsEmptyTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.accountsEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.muted,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: Text(l10n.accountsAddNew),
              onPressed: () => showAccountsManagerDialog(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前激活账号下还没有任何 tab 时的提示。
class _NoTabState extends StatelessWidget {
  const _NoTabState();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final mobileNav = _MobileWorkspaceNavActions.maybeOf(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Icon(
                  Icons.rocket_launch_outlined,
                  size: 32,
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.workspaceNoProjectTabTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.workspaceNoProjectTabSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.55,
                ),
              ),
              if (context.isMobile && mobileNav != null) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.account_tree_rounded),
                  label: Text(l10n.workspaceNoProjectTabOpenProjects),
                  onPressed: () => mobileNav.selectBottomNavIndex(
                    _MobileShellState._mobileNavProjects,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
