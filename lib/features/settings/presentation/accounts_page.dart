import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/http/jenkins_http_client.dart';
import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../application/network_proxy_state_provider.dart';
import '../data/accounts_export_save.dart';
import '../data/accounts_import_pick.dart';
import '../data/jenkins_account_qr_share.dart';
import '../data/jenkins_accounts_bulk_export.dart';
import '../data/jenkins_accounts_repository.dart';
import '../domain/jenkins_account.dart';
import '../domain/jenkins_config.dart';
import '../../workspace/application/workspace_controller.dart';
import 'jenkins_account_qr_scan_page.dart';

/// 仅 iOS / Android 显示「扫码导入」；桌面与 Web 仅手动添加账号。
bool _accountsSupportQrScanImport() {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
      return true;
    default:
      return false;
  }
}

/// 仅桌面端（macOS / Windows / Linux）支持导出配置文件。
bool _accountsSupportDesktopExport() {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

String _bulkImportFailureMessage(AppL10n l10n, JenkinsBulkImportFailure f) {
  return switch (f) {
    JenkinsBulkImportFailure.emptyPayload => l10n.accountsImportBulkErrorEmpty,
    JenkinsBulkImportFailure.unrecognizedFormat => l10n.accountsImportBulkErrorFormat,
    JenkinsBulkImportFailure.encryptedNeedsPassword =>
      l10n.accountsImportBulkErrorNeedPassword,
    JenkinsBulkImportFailure.wrongPasswordOrCorrupt =>
      l10n.accountsImportBulkErrorDecrypt,
    JenkinsBulkImportFailure.noValidAccounts => l10n.accountsImportBulkErrorNoAccounts,
  };
}

/// 账号管理对话框入口。
///
/// - 桌面 / 平板上以居中弹窗呈现；
/// - 窄屏（< 720）上以「全屏对话框」push 一个 route，避免弹窗被截断。
Future<void> showAccountsManagerDialog(BuildContext context) async {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 720) {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: const AccountsManagerView(compactHeader: false),
        ),
      ),
    );
  } else {
    final rootNav = Navigator.of(context, rootNavigator: true);
    Widget mobileAccountsScaffold(BuildContext ctx) => Scaffold(
          appBar: AppBar(
            title: Text(AppL10n.of(ctx).accountsTitle),
          ),
          body: const SafeArea(
            child: AccountsManagerView(compactHeader: true),
          ),
        );
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await rootNav.push<void>(
        CupertinoPageRoute<void>(
          builder: mobileAccountsScaffold,
        ),
      );
    } else {
      await rootNav.push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: mobileAccountsScaffold,
        ),
      );
    }
  }
}

/// 扫码导入受 PIN 保护载荷时：四个方框输入验证码，点击导入后在弹窗内解码，成功再关闭并返回账号。
class _JenkinsSharePinDialog extends StatefulWidget {
  const _JenkinsSharePinDialog({required this.protectedPayload});

  final String protectedPayload;

  @override
  State<_JenkinsSharePinDialog> createState() => _JenkinsSharePinDialogState();
}

class _JenkinsSharePinDialogState extends State<_JenkinsSharePinDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _busy = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    void onPinOrFocusChanged() {
      if (!mounted) return;
      setState(() {
        if (_errorText != null) _errorText = null;
      });
    }

    _controller.addListener(onPinOrFocusChanged);
    _focusNode.addListener(onPinOrFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _trySubmit() async {
    final pin = _controller.text;
    if (_busy || !isValidJenkinsSharePinFormat(pin)) return;

    setState(() {
      _busy = true;
      _errorText = null;
    });

    final decoded =
        await decodeJenkinsAccountShare(widget.protectedPayload, pin: pin);

    if (!mounted) return;

    if (decoded != null) {
      Navigator.of(context).pop(decoded);
      return;
    }

    setState(() {
      _busy = false;
      _errorText = AppL10n.of(context).accountsImportPinWrongOrCorrupt;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final pin = _controller.text;
    final hasFocus = _focusNode.hasFocus;
    final nextIndex = pin.length.clamp(0, 4);

    return AlertDialog(
      title: Text(l10n.accountsImportPinTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.accountsImportPinBody),
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.hardEdge,
              children: [
                GestureDetector(
                  onTap: () => _focusNode.requestFocus(),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(4, (i) {
                      final digit = i < pin.length ? pin[i] : '';
                      final focusedSlot = hasFocus && nextIndex == i;
                      return Padding(
                        padding: EdgeInsets.only(left: i == 0 ? 0 : 10),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOut,
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.surfaceRaised,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              width: focusedSlot ? 2 : 1,
                              color: focusedSlot ? palette.accent : palette.border,
                            ),
                          ),
                          child: Text(
                            digit,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: palette.text,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                // 输入框放在可视区域外并由 Stack 裁切，避免 Material InputDecorator 叠在格子上仍露出底色/描边。
                Positioned(
                  left: -8000,
                  width: 160,
                  height: 44,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      inputDecorationTheme: const InputDecorationTheme(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        filled: true,
                        fillColor: Colors.transparent,
                        hoverColor: Colors.transparent,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      showCursor: false,
                      enableInteractiveSelection: false,
                      scrollPadding: EdgeInsets.zero,
                      style: const TextStyle(color: Colors.transparent, height: 1),
                      strutStyle: const StrutStyle(fontSize: 1, height: 1),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        counterText: '',
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!_busy && isValidJenkinsSharePinFormat(_controller.text)) {
                          _trySubmit();
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorText!,
              style: TextStyle(color: palette.danger, fontSize: 13, height: 1.35),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed:
              (!isValidJenkinsSharePinFormat(pin) || _busy) ? null : () => _trySubmit(),
          child: _busy
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                )
              : Text(l10n.accountsImportPinConfirm),
        ),
      ],
    );
  }
}

/// 账号管理视图本体（不带外层弹窗 chrome）。
///
/// 既可作为 [showAccountsManagerDialog] 的 dialog body，也可以独立嵌入 Scaffold。
///
/// 列表选中态仅存于本页（点击卡片高亮），不与全局 Jenkins 激活账号或一级 tab 联动。
class AccountsManagerView extends ConsumerStatefulWidget {
  const AccountsManagerView({super.key, this.compactHeader = false});

  /// 窄屏全屏页：外层已有 [AppBar] 标题时，不再重复绘制页内标题栏。
  final bool compactHeader;

  @override
  ConsumerState<AccountsManagerView> createState() => _AccountsManagerViewState();
}

class _AccountsManagerViewState extends ConsumerState<AccountsManagerView> {
  String? _selectedAccountId;

  Future<void> _showEditor(
    BuildContext context,
    WidgetRef ref, {
    JenkinsAccount? account,
  }) async {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final navigator = Navigator.of(context, rootNavigator: true);
    final JenkinsAccount? saved;
    if (narrow) {
      Widget editorRouteChild() =>
          _AccountEditorDialog(initial: account, fullscreen: true);
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        saved = await navigator.push<JenkinsAccount>(
          CupertinoPageRoute<JenkinsAccount>(
            builder: (_) => editorRouteChild(),
          ),
        );
      } else {
        saved = await navigator.push<JenkinsAccount>(
          MaterialPageRoute<JenkinsAccount>(
            fullscreenDialog: false,
            builder: (_) => editorRouteChild(),
          ),
        );
      }
    } else {
      saved = await showDialog<JenkinsAccount>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) =>
            _AccountEditorDialog(initial: account, fullscreen: false),
      );
    }
    if (saved == null) return;
    final isNew = account == null;
    await ref.read(jenkinsAccountsProvider.notifier).upsert(saved);
    if (!context.mounted) return;
    final l10n = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isNew ? l10n.accountsCreated : l10n.accountsUpdated)),
    );
  }

  Future<void> _confirmRemove(
      BuildContext context, WidgetRef ref, JenkinsAccount account) async {
    final l10n = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.accountsRemoveConfirmTitle),
        content: Text(l10n.accountsRemoveConfirmBody(account.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: context.palette.danger),
            child: Text(l10n.accountsRemove),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(jenkinsAccountsProvider.notifier).remove(account.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.accountsRemoved)));
  }

  Future<void> _showShareQr(BuildContext context, JenkinsAccount account) async {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final pin = generateJenkinsSharePin();
    late final String payload;
    try {
      payload = await encodeJenkinsAccountShareProtected(account, pin);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorUnknown('$e'))),
      );
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        Widget qrWidget;
        try {
          qrWidget = QrImageView(
            data: payload,
            version: QrVersions.auto,
            size: 216,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          );
        } catch (e) {
          qrWidget = Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.errorUnknown('$e'),
              style: TextStyle(color: palette.danger, fontSize: 12),
            ),
          );
        }
        final mq = MediaQuery.sizeOf(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 400, maxHeight: mq.height * 0.88),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: palette.accent, size: 22),
                      Text(
                        l10n.accountsShareQrTitle,
                        style: Theme.of(ctx).textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.accountsShareQrWarning,
                    style: TextStyle(color: palette.danger, fontSize: 12, height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.accountsShareQrPinHint,
                    style: TextStyle(color: palette.muted, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.surfaceRaised,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.borderSubtle),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: Text(
                          pin,
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: palette.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.accountsShareQrPinLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: palette.borderSubtle),
                      ),
                      child: qrWidget,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(l10n.commonClose),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<JenkinsAccount?> _decodePinProtectedShareInDialog(
    BuildContext context,
    String protectedPayload,
  ) {
    return showDialog<JenkinsAccount>(
      context: context,
      builder: (ctx) => _JenkinsSharePinDialog(protectedPayload: protectedPayload),
    );
  }

  Future<void> _openQrScanImport(BuildContext context, WidgetRef ref) async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => const JenkinsAccountQrScanPage(),
      ),
    );
    if (!context.mounted || raw == null) return;
    await _applyImportedSharePayload(context, ref, raw);
  }

  Future<void> _showDesktopExportAccounts(BuildContext context, WidgetRef ref) async {
    if (!_accountsSupportDesktopExport()) return;
    final s = ref.read(jenkinsAccountsProvider).value;
    final accounts = s?.accounts ?? [];
    if (accounts.isEmpty) return;

    final password = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => const _DesktopExportAccountsDialog(),
    );
    if (!context.mounted || password == null) return;

    final l10n = AppL10n.of(context);
    try {
      final content = await encodeJenkinsAccountsExport(accounts, password);
      final ok =
          await saveAccountsExportFile(content, 'deployment-jenkins-accounts.json');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? l10n.accountsExportSuccess : l10n.accountsExportSaveCancelled),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.accountsExportFailed('$e'))),
      );
    }
  }

  Future<void> _showDesktopImportAccounts(BuildContext context, WidgetRef ref) async {
    if (!_accountsSupportDesktopExport()) return;
    final l10n = AppL10n.of(context);
    final raw = await pickAndReadAccountsImportFile();
    if (!context.mounted) return;
    if (raw == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.accountsImportBulkPickCancelled)),
      );
      return;
    }

    final password = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => const _DesktopImportAccountsDialog(),
    );
    if (!context.mounted || password == null) return;

    late final List<JenkinsAccount> imported;
    try {
      imported = await decodeJenkinsAccountsExport(raw, password);
    } on JenkinsBulkImportDecodeException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_bulkImportFailureMessage(l10n, e.failure))),
      );
      return;
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.accountsImportBulkFailed('$e'))),
      );
      return;
    }

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.accountsImportBulkMergeTitle),
        content: Text(l10n.accountsImportBulkMergeBody(imported.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.accountsImportBulkMergeConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ref.read(jenkinsAccountsProvider.notifier).mergeImportedAccounts(imported);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.accountsImportBulkFailed('$e'))),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.accountsImportBulkSuccess(imported.length))),
    );
  }

  Future<void> _applyImportedSharePayload(
    BuildContext context,
    WidgetRef ref,
    String text,
  ) async {
    final l10n = AppL10n.of(context);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    late final JenkinsAccount account;
    if (isJenkinsPinProtectedSharePayload(trimmed)) {
      final decoded = await _decodePinProtectedShareInDialog(context, trimmed);
      if (!context.mounted) return;
      if (decoded == null) return;
      account = decoded;
    } else {
      final decoded = await decodeJenkinsAccountShare(trimmed);
      if (!context.mounted) return;
      if (decoded == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.accountsImportInvalid)),
        );
        return;
      }
      account = decoded;
    }

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.accountsImportConfirmTitle),
        content: Text(
          l10n.accountsImportConfirmBody(
            account.config.displayHost,
            account.config.username,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.accountsAddNew),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(jenkinsAccountsProvider.notifier).upsert(account);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.accountsImportedFromShare)),
    );
  }

  Widget _buildMobileReorderableAccounts(
    BuildContext context,
    JenkinsAccountsState s,
    String? mobileHighlightId,
  ) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Text(
            l10n.accountsReorderHintMobile,
            style: TextStyle(
              fontSize: 12,
              color: palette.muted,
              height: 1.35,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
            itemCount: s.accounts.length,
            onReorder: (oldIndex, newIndex) {
              unawaited(
                ref
                    .read(jenkinsAccountsProvider.notifier)
                    .reorderAccounts(oldIndex, newIndex),
              );
            },
            itemBuilder: (ctx, i) {
              final a = s.accounts[i];
              final selected = mobileHighlightId == a.id;
              return KeyedSubtree(
                key: ValueKey(a.id),
                child: Padding(
                  padding: EdgeInsets.only(bottom: i < s.accounts.length - 1 ? 10 : 0),
                  child: ReorderableDelayedDragStartListener(
                    index: i,
                    child: _AccountCard(
                      account: a,
                      isSelected: selected,
                      onSelect: () {
                        final notifier = ref.read(workspaceProvider.notifier);
                        final strip = ref.read(workspaceProvider).openedAccountIds;
                        if (strip.contains(a.id)) {
                          notifier.activateAccountInStrip(a.id);
                        } else {
                          notifier.openAccountInStrip(a.id);
                        }
                      },
                      onShareQr: () => _showShareQr(context, a),
                      onEdit: () => _showEditor(context, ref, account: a),
                      onRemove: () => _confirmRemove(context, ref, a),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final accountsAsync = ref.watch(jenkinsAccountsProvider);

    return accountsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l10n.errorUnknown(e.toString()))),
      data: (s) {
        final validIds = s.accounts.map((a) => a.id).toSet();
        if (_selectedAccountId != null && !validIds.contains(_selectedAccountId)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedAccountId = null);
          });
        }

        final ws = ref.watch(workspaceProvider);
        final effectiveSelectedId =
            _selectedAccountId ?? ws.activeAccountId ?? s.activeId;

        final mobileHighlightId = ws.activeAccountId ?? s.activeId;

        return Container(
          color: palette.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.compactHeader) ...[
                _Header(title: l10n.accountsTitle, palette: palette),
                Divider(height: 1, color: palette.borderSubtle),
              ],
              Expanded(
                child: s.accounts.isEmpty
                    ? _EmptyState(
                        palette: palette,
                        onAdd: () => _showEditor(context, ref),
                        onScanImport: _accountsSupportQrScanImport()
                            ? () => _openQrScanImport(context, ref)
                            : null,
                        onDesktopImport: _accountsSupportDesktopExport()
                            ? () => _showDesktopImportAccounts(context, ref)
                            : null,
                      )
                    : context.isMobile
                        ? _buildMobileReorderableAccounts(
                            context,
                            s,
                            mobileHighlightId,
                          )
                        : ListView.separated(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            itemCount: s.accounts.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (ctx, i) {
                              final a = s.accounts[i];
                              final selected = effectiveSelectedId == a.id;
                              return _AccountCard(
                                account: a,
                                isSelected: selected,
                                onSelect: () {
                                  setState(() => _selectedAccountId = a.id);
                                },
                                onShareQr: () => _showShareQr(context, a),
                                onEdit: () => _showEditor(context, ref, account: a),
                                onRemove: () => _confirmRemove(context, ref, a),
                              );
                            },
                          ),
              ),
              if (s.accounts.isNotEmpty) ...[
                Divider(height: 1, color: palette.borderSubtle),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
                  child: Row(
                    children: [
                      Text(
                        l10n.accountsCount(s.accounts.length),
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                      const Spacer(),
                      if (_accountsSupportDesktopExport()) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.file_upload_outlined, size: 16),
                          label: Text(l10n.accountsImportConfig),
                          onPressed: () => _showDesktopImportAccounts(context, ref),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.file_download_outlined, size: 16),
                          label: Text(l10n.accountsExportConfig),
                          onPressed: () => _showDesktopExportAccounts(context, ref),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (_accountsSupportQrScanImport()) ...[
                        OutlinedButton.icon(
                          icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                          label: Text(l10n.accountsImportScanQr),
                          onPressed: () => _openQrScanImport(context, ref),
                        ),
                        const SizedBox(width: 10),
                      ],
                      FilledButton.icon(
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: Text(l10n.accountsAddNew),
                        onPressed: () => _showEditor(context, ref),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DesktopImportAccountsDialog extends StatefulWidget {
  const _DesktopImportAccountsDialog();

  @override
  State<_DesktopImportAccountsDialog> createState() =>
      _DesktopImportAccountsDialogState();
}

class _DesktopImportAccountsDialogState extends State<_DesktopImportAccountsDialog> {
  final _pwd = TextEditingController();

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    return AlertDialog(
      title: Text(l10n.accountsImportBulkTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.accountsImportBulkBody,
              style: TextStyle(color: palette.text, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pwd,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.accountsExportPasswordLabel,
                hintText: l10n.accountsExportPasswordHint,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pwd.text),
          child: Text(l10n.accountsImportBulkConfirm),
        ),
      ],
    );
  }
}

class _DesktopExportAccountsDialog extends StatefulWidget {
  const _DesktopExportAccountsDialog();

  @override
  State<_DesktopExportAccountsDialog> createState() =>
      _DesktopExportAccountsDialogState();
}

class _DesktopExportAccountsDialogState extends State<_DesktopExportAccountsDialog> {
  final _pwd = TextEditingController();

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    return AlertDialog(
      title: Text(l10n.accountsExportTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.accountsExportBody,
              style: TextStyle(color: palette.text, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pwd,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.accountsExportPasswordLabel,
                hintText: l10n.accountsExportPasswordHint,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pwd.text),
          child: Text(l10n.accountsExportConfirm),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.palette});

  final String title;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: Icon(Icons.manage_accounts_rounded, color: palette.accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: palette.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: AppL10n.of(context).commonClose,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.palette,
    required this.onAdd,
    this.onScanImport,
    this.onDesktopImport,
  });

  final AppPalette palette;
  final VoidCallback onAdd;
  final VoidCallback? onScanImport;
  final VoidCallback? onDesktopImport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 36, color: palette.muted),
            const SizedBox(height: 12),
            Text(
              l10n.accountsEmptyTitle,
              style: TextStyle(color: palette.text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.accountsEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.55),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.add_rounded, size: 16),
              label: Text(l10n.accountsAddNew),
              onPressed: onAdd,
            ),
            if (onDesktopImport != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_upload_outlined, size: 16),
                label: Text(l10n.accountsImportConfig),
                onPressed: onDesktopImport,
              ),
            ],
            if (onScanImport != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                label: Text(l10n.accountsImportScanQr),
                onPressed: onScanImport,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.isSelected,
    required this.onSelect,
    required this.onShareQr,
    required this.onEdit,
    required this.onRemove,
  });

  final JenkinsAccount account;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onShareQr;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? palette.accent.withValues(alpha: 0.65) : palette.borderSubtle,
          width: isSelected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          hoverColor: palette.hoverOverlay,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Icon(
                    isSelected ? Icons.cloud_done_rounded : Icons.cloud_outlined,
                    size: 18,
                    color: isSelected ? palette.accent : palette.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        account.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 11.5),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${account.config.username} · ${account.config.authKind == JenkinsAuthKind.token ? l10n.settingsAuthToken : l10n.settingsAuthPassword}',
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: l10n.accountsShareQrTooltip,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                    onPressed: onShareQr,
                  ),
                ),
                Tooltip(
                  message: l10n.accountsEdit,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: onEdit,
                  ),
                ),
                Tooltip(
                  message: l10n.accountsRemove,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: Icon(Icons.delete_outline_rounded, size: 18, color: palette.danger),
                    onPressed: onRemove,
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

/// 账号编辑器：宽屏用 Dialog；窄屏用全屏 [Scaffold]（避免 iOS 上 Dialog 内 TextField 无法唤起键盘）。
class _AccountEditorDialog extends ConsumerStatefulWidget {
  const _AccountEditorDialog({this.initial, this.fullscreen = false});

  final JenkinsAccount? initial;
  final bool fullscreen;

  @override
  ConsumerState<_AccountEditorDialog> createState() => _AccountEditorDialogState();
}

class _AccountEditorDialogState extends ConsumerState<_AccountEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _baseUrlCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _secretCtrl;

  late JenkinsAuthKind _kind;
  bool _testing = false;
  bool _saving = false;
  String? _testInfo;
  String? _testError;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _nameCtrl = TextEditingController(text: init?.name ?? '');
    _baseUrlCtrl = TextEditingController(text: init?.config.baseUrl ?? '');
    _userCtrl = TextEditingController(text: init?.config.username ?? '');
    _secretCtrl = TextEditingController(text: init?.config.secret ?? '');
    _kind = init?.config.authKind ?? JenkinsAuthKind.token;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _userCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  JenkinsConfig _draftConfig() => JenkinsConfig(
        baseUrl: _baseUrlCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        secret: _secretCtrl.text,
        authKind: _kind,
      );

  Future<void> _onTest() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _testError = null;
      _testInfo = null;
    });
    try {
      final res = await testJenkinsConnection(
        _draftConfig(),
        networkProxy: ref.read(networkProxyStateProvider),
      );
      if (!mounted) return;
      setState(() => _testInfo =
          '✓ ${AppL10n.of(context).settingsConnected}${res.version.isNotEmpty ? ' · ${res.version}' : ''}');
    } catch (e) {
      if (!mounted) return;
      final msg = e is JenkinsException ? e.message : e.toString();
      setState(() => _testError = msg);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _onSave() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final cfg = _draftConfig();
      final id = widget.initial?.id ?? _generateId(cfg);
      final name = _nameCtrl.text.trim().isEmpty ? cfg.displayHost : _nameCtrl.text.trim();
      final account = JenkinsAccount(id: id, name: name, config: cfg);
      if (!mounted) return;
      Navigator.of(context).pop(account);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _generateId(JenkinsConfig cfg) {
    final base =
        '${cfg.username}@${cfg.displayHost}'.replaceAll(RegExp(r'[^A-Za-z0-9_.@-]'), '_');
    return '$base-${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final isEdit = widget.initial != null;
    final mq = MediaQuery.of(context);
    final maxW = (mq.size.width - 28).clamp(280.0, 520.0);
    final kb = mq.viewInsets.bottom;
    // 桌面弹窗：表单区最大高度按内容滚动，避免整窗接近满屏（此前 fixed height + max 920 过高）。
    final editorScrollMaxH =
        (mq.size.height - mq.padding.vertical - kb - 160).clamp(200.0, 520.0);

    Widget actionBar() => Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt_rounded, size: 16),
                label: Text(l10n.settingsTest),
                onPressed: _testing ? null : _onTest,
              ),
              if (!widget.fullscreen)
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
              FilledButton.icon(
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_rounded, size: 16),
                label: Text(l10n.settingsSave),
                onPressed: _saving ? null : _onSave,
              ),
            ],
          ),
        );

    final formColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          label: l10n.accountsName,
          hint: l10n.accountsNameHint,
          child: TextFormField(
            controller: _nameCtrl,
            autofocus: widget.fullscreen,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.label_outline_rounded, size: 18),
            ),
          ),
        ),
        _field(
          label: l10n.settingsBaseUrl,
          child: TextFormField(
            controller: _baseUrlCtrl,
            keyboardType: TextInputType.url,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: InputDecoration(
              hintText: l10n.settingsBaseUrlHint,
              prefixIcon: const Icon(Icons.link_rounded, size: 18),
            ),
            validator: (v) {
              final t = v?.trim() ?? '';
              if (t.isEmpty) return l10n.settingsRequiredAll;
              if (!t.startsWith('http')) return 'URL 应以 http(s):// 开头';
              return null;
            },
          ),
        ),
        _field(
          label: l10n.settingsUsername,
          hint: l10n.settingsUsernameHint,
          child: TextFormField(
            controller: _userCtrl,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
            ),
            validator: (v) =>
                (v?.trim().isEmpty ?? true) ? l10n.settingsRequiredAll : null,
          ),
        ),
        _field(
          label: l10n.settingsAuthKind,
          child: SegmentedButton<JenkinsAuthKind>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: JenkinsAuthKind.token,
                label: Text(l10n.settingsAuthToken),
                icon: const Icon(Icons.vpn_key_rounded, size: 16),
              ),
              ButtonSegment(
                value: JenkinsAuthKind.password,
                label: Text(l10n.settingsAuthPassword),
                icon: const Icon(Icons.password_rounded, size: 16),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
        ),
        _field(
          label: _kind == JenkinsAuthKind.token
              ? l10n.settingsSecretToken
              : l10n.settingsSecretPassword,
          hint: _kind == JenkinsAuthKind.token
              ? l10n.settingsTokenHint
              : l10n.settingsPasswordHint,
          child: TextFormField(
            controller: _secretCtrl,
            obscureText: true,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.lock_outline_rounded, size: 18),
            ),
            validator: (v) =>
                (v?.isEmpty ?? true) ? l10n.settingsRequiredAll : null,
          ),
        ),
        if (_testInfo != null)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: palette.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.success.withValues(alpha: 0.4)),
            ),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, size: 14, color: palette.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_testInfo!,
                    style: TextStyle(color: palette.text, fontSize: 12)),
              ),
            ]),
          ),
        if (_testError != null)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: palette.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.danger.withValues(alpha: 0.4)),
            ),
            child: Row(children: [
              Icon(Icons.error_rounded, size: 14, color: palette.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_testError!,
                    style: TextStyle(color: palette.text, fontSize: 12)),
              ),
            ]),
          ),
      ],
    );

    if (widget.fullscreen) {
      return Scaffold(
        backgroundColor: palette.surface,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: Text(isEdit ? l10n.accountsEdit : l10n.accountsAddNew),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Form(
                  key: _formKey,
                  child: formColumn,
                ),
              ),
            ),
            Divider(height: 1, color: palette.borderSubtle),
            SafeArea(top: false, child: actionBar()),
          ],
        ),
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
              child: Text(
                isEdit ? l10n.accountsEdit : l10n.accountsAddNew,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: editorScrollMaxH),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
                physics: const ClampingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
                children: [
                  Form(
                    key: _formKey,
                    child: formColumn,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.borderSubtle),
            actionBar(),
          ],
        ),
      ),
    );
  }

  Widget _field({required String label, String? hint, required Widget child}) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: palette.muted, fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          child,
          if (hint != null && hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child:
                  Text(hint, style: TextStyle(color: palette.muted, fontSize: 11, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
