import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/horizontal_tab_scroll.dart';
import '../../../l10n/app_localizations.dart';
import '../../settings/data/jenkins_accounts_repository.dart';
import '../../settings/domain/jenkins_account.dart';
import '../../settings/presentation/accounts_page.dart';
import '../application/workspace_controller.dart';

/// 弹出「已配置的 Jenkins 账号」列表，选择后在顶级栏打开对应标签。
Future<void> showJenkinsWorkspacePicker(BuildContext context, WidgetRef ref) async {
  final l10n = AppL10n.of(context);
  final accounts = ref.read(jenkinsAccountsProvider).value?.accounts ?? [];
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.workspacePickerNoAccounts)),
    );
    return;
  }

  final size = MediaQuery.sizeOf(context);

  Future<void> pick(JenkinsAccount a) async {
    await ref.read(workspaceProvider.notifier).openAccountInStrip(a.id);
  }

  if (size.width >= 720) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.workspacePickerTitle),
        content: SizedBox(
          width: 420,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: accounts.length,
            itemBuilder: (_, i) {
              final a = accounts[i];
              final open = ref.read(workspaceProvider).openedAccountIds.contains(a.id);
              return ListTile(
                leading: Icon(
                  open ? Icons.check_circle_outline_rounded : Icons.circle_outlined,
                  size: 22,
                  color: open ? Theme.of(ctx).colorScheme.primary : null,
                ),
                title: Text(a.displayName),
                subtitle: Text(
                  a.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await pick(a);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final maxH = MediaQuery.sizeOf(ctx).height * 0.65;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Text(
                    l10n.workspacePickerTitle,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: accounts.length,
                    itemBuilder: (_, i) {
                      final a = accounts[i];
                      final open = ref.read(workspaceProvider).openedAccountIds.contains(a.id);
                      return ListTile(
                        leading: Icon(
                          open ? Icons.check_circle_outline_rounded : Icons.circle_outlined,
                          color: open ? Theme.of(ctx).colorScheme.primary : null,
                        ),
                        title: Text(a.displayName),
                        subtitle: Text(
                          a.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          Navigator.of(ctx).pop();
                          await pick(a);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 最外层「账号 tab 栏」：切换已打开的 Jenkins 工作区；可选「+」、标签关闭、人像（账号管理）。
///
/// 移动端「项目」「构建」顶栏：通常三者皆 false，只切换已打开的工作区；打开/关闭工作区与账号管理走底部「账户」。
class WorkspaceAccountBar extends ConsumerWidget {
  const WorkspaceAccountBar({
    super.key,
    this.allowOpenWorkspace = true,
    this.allowCloseWorkspaceStrip = true,
    this.allowManageAccountsButton = true,
  });

  /// 打开更多工作区标签（「+」）。
  final bool allowOpenWorkspace;

  /// 关闭一级工作区标签（芯片上的 ×）。
  final bool allowCloseWorkspaceStrip;

  /// 快捷打开账号管理弹窗。
  final bool allowManageAccountsButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final accountsAsync = ref.watch(jenkinsAccountsProvider);
    final accounts = accountsAsync.value?.accounts ?? const <JenkinsAccount>[];
    final ws = ref.watch(workspaceProvider);

    final idToAccount = {for (final a in accounts) a.id: a};
    final stripHeight = context.isMobile ? 42.0 : 48.0;

    return Container(
      height: stripHeight,
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(
          bottom: BorderSide(color: palette.borderSubtle, width: 0.8),
        ),
      ),
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 6),
            child: Icon(Icons.workspaces_outlined, size: 14, color: palette.muted),
          ),
          Expanded(
            child: ws.openedAccountIds.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        allowOpenWorkspace
                            ? l10n.workspaceEmptyStripHint
                            : l10n.workspaceEmptyStripHintReadOnly,
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    ),
                  )
                : HorizontalScrollStrip(
                    itemCount: ws.openedAccountIds.length,
                    itemBuilder: (ctx, i) {
                      final id = ws.openedAccountIds[i];
                      final account = idToAccount[id];
                      if (account == null) return const SizedBox.shrink();
                      final active = id == ws.activeAccountId;
                      return _AccountChip(
                        account: account,
                        active: active,
                        showClose: allowCloseWorkspaceStrip,
                        onActivate: () =>
                            ref.read(workspaceProvider.notifier).activateAccountInStrip(account.id),
                        onClose: () =>
                            ref.read(workspaceProvider.notifier).closeAccountInStrip(account.id),
                      );
                    },
                  ),
          ),
          if (allowOpenWorkspace)
            Tooltip(
              message: l10n.workspaceAddJenkinsTooltip,
              child: IconButton(
                icon: const Icon(Icons.add_rounded, size: 18),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                constraints: const BoxConstraints.tightFor(width: 36, height: 32),
                splashRadius: 14,
                onPressed: () => showJenkinsWorkspacePicker(context, ref),
              ),
            ),
          if (allowManageAccountsButton)
            Tooltip(
              message: l10n.accountsManage,
              child: IconButton(
                icon: const Icon(Icons.manage_accounts_rounded, size: 18),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                constraints: const BoxConstraints.tightFor(width: 36, height: 32),
                splashRadius: 14,
                onPressed: () => showAccountsManagerDialog(context),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _AccountChip extends StatefulWidget {
  const _AccountChip({
    required this.account,
    required this.active,
    required this.showClose,
    required this.onActivate,
    required this.onClose,
  });

  final JenkinsAccount account;
  final bool active;
  final bool showClose;
  final VoidCallback onActivate;
  final VoidCallback onClose;

  @override
  State<_AccountChip> createState() => _AccountChipState();
}

class _AccountChipState extends State<_AccountChip> {
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
    final account = widget.account;
    final active = widget.active;

    final fg = active ? palette.text : palette.muted;
    final bgColor = active
        ? palette.surfaceRaised
        : (_hovered ? palette.hoverOverlay : Colors.transparent);
    final borderSide = active
        ? BorderSide(color: palette.accent.withValues(alpha: 0.55), width: 1.2)
        : BorderSide(color: palette.borderSubtle, width: 0.8);

    return MouseRegion(
      onEnter: (_) => _setHoveredDeferred(true),
      onExit: (_) => _setHoveredDeferred(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivate,
        child: Container(
          margin: EdgeInsets.symmetric(
            horizontal: 3,
            vertical: context.isMobile ? 3 : 5,
          ),
          padding: EdgeInsets.only(left: 12, right: widget.showClose ? 4 : 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.fromBorderSide(borderSide),
          ),
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active ? palette.accent : palette.muted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  account.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.showClose) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: AppL10n.of(context).workspaceClosePrimaryTab,
                  child: InkWell(
                    onTap: widget.onClose,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: (_hovered || active) ? palette.muted : palette.muted.withValues(alpha: 0.35),
                      ),
                    ),
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
