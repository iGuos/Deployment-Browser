import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/locale/app_locale_controller.dart';
import '../../../core/notifications/build_notifier.dart';
import '../../../core/notifications/notifications_settings.dart';
import '../../../core/theme/accent_color_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/error_log_service.dart';
import '../../../core/widgets/top_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../notifications/slack/slack_notifier.dart';
import 'error_log_viewer.dart';
import 'proxy_settings_window.dart';

/// 应用级设置：菜单说明、主题、语言、代理。
Future<void> showAppSettingsDialog(BuildContext hostContext) {
  return showDialog<void>(
    context: hostContext,
    builder: (ctx) => _AppSettingsDialog(hostContext: hostContext),
  );
}

class _AppSettingsDialog extends ConsumerWidget {
  const _AppSettingsDialog({required this.hostContext});

  /// 用于关闭对话框后仍打开代理弹窗 / 子窗口（勿用对话框自身 [context]）。
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(appLocaleProvider);
    final size = MediaQuery.sizeOf(context);

    return AlertDialog(
      title: Text(l10n.settingsDialogTitle),
      content: SizedBox(
        width: math.min(620, size.width - 80),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(
                icon: Icons.menu_rounded,
                title: l10n.settingsSectionMenu,
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  l10n.settingsSectionMenuHint,
                  style: TextStyle(color: palette.muted, fontSize: 12, height: 1.35),
                ),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionHeader(
                icon: Icons.palette_outlined,
                title: l10n.settingsSectionTheme,
              ),
              const SizedBox(height: 8),
              RadioGroup<ThemeMode>(
                groupValue: themeMode,
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(themeModeProvider.notifier).setMode(v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: ThemeMode.values
                      .map(
                        (m) => Padding(
                          padding: const EdgeInsets.only(left: 18),
                          child: RadioListTile<ThemeMode>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: m,
                            title: Text(
                              switch (m) {
                                ThemeMode.system => l10n.themeFollowSystem,
                                ThemeMode.dark => l10n.themeDark,
                                ThemeMode.light => l10n.themeLight,
                              },
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: _AccentColorRow(),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionHeader(
                icon: Icons.translate_rounded,
                title: l10n.settingsSectionLanguage,
              ),
              const SizedBox(height: 8),
              RadioGroup<Locale>(
                groupValue: locale,
                onChanged: (v) {
                  if (v == null) return;
                  ref.read(appLocaleProvider.notifier).setLocale(v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 18),
                      child: RadioListTile<Locale>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: const Locale('zh'),
                        title: Text(l10n.settingsLanguageZh, style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 18),
                      child: RadioListTile<Locale>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: const Locale('en'),
                        title: Text(l10n.settingsLanguageEn, style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionHeader(
                icon: Icons.notifications_active_outlined,
                title: l10n.settingsSectionNotifications,
              ),
              _NotificationsToggle(),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionTile(
                icon: Icons.forum_outlined,
                title: l10n.settingsSectionSlack,
                subtitle: l10n.settingsSlackHint,
                trailing: ref.watch(slackConfigProvider.select((c) => c.isConfigured))
                    ? Icon(Icons.check_circle_rounded, size: 16, color: palette.success)
                    : null,
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _SlackSettingsDialog(),
                ),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionTile(
                icon: Icons.vpn_lock_rounded,
                title: l10n.settingsSectionProxy,
                subtitle: l10n.settingsProxyOpenHint,
                onTap: () async {
                  Navigator.of(context).pop();
                  await openAppProxySettings(context: hostContext);
                },
              ),
              Divider(height: 24, color: palette.borderSubtle),
              ListenableBuilder(
                listenable: errorLogService,
                builder: (ctx, _) {
                  final count = errorLogService.entries.length;
                  return _SectionTile(
                    icon: Icons.bug_report_outlined,
                    title: l10n.settingsSectionErrorLog,
                    subtitle: l10n.settingsSectionErrorLogHint,
                    trailing: count > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: palette.danger.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: palette.danger.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                color: palette.danger,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : null,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await showErrorLogViewer(hostContext);
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

/// 主题强调色选择：默认 + 一排预设色，点选即时生效并持久化。
class _AccentColorRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final current = ref.watch(accentColorProvider);

    Widget swatch({required Color? color, required bool selected}) {
      final display = color ?? palette.accent;
      return InkWell(
        onTap: () => ref.read(accentColorProvider.notifier).setAccent(color),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color == null ? Colors.transparent : display,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? palette.text : palette.borderSubtle,
              width: selected ? 2 : 1,
            ),
          ),
          child: color == null
              ? Icon(Icons.format_color_reset_outlined, size: 14, color: palette.muted)
              : (selected ? const Icon(Icons.check, size: 14, color: Colors.white) : null),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          l10n.settingsAccentColor,
          style: TextStyle(color: palette.muted, fontSize: 12.5),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              swatch(color: null, selected: current == null),
              for (final c in kAccentColorPresets)
                swatch(
                  color: c,
                  selected: current != null && current.toARGB32() == c.toARGB32(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Slack 通知配置弹框:开关 + token + 权限检测 + 多选接收人 + 成功/失败 + 测试。
class _SlackSettingsDialog extends ConsumerStatefulWidget {
  const _SlackSettingsDialog();

  @override
  ConsumerState<_SlackSettingsDialog> createState() => _SlackSettingsDialogState();
}

class _SlackSettingsDialogState extends ConsumerState<_SlackSettingsDialog> {
  static const _tokenMask = '••••••••••••••••';

  final _tokenCtrl = TextEditingController();
  final _tokenFocus = FocusNode();
  final _successTplCtrl = TextEditingController();
  final _failureTplCtrl = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  bool _checking = false;
  // 已配置 token 时,字段用圆点占位（不暴露真实 token）。聚焦即清空以便输入新值;
  // 失焦且未输入则恢复占位。
  bool _tokenMasked = false;
  SlackAuth? _auth;
  String? _checkError;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(slackConfigProvider);
    if (cfg.hasToken) {
      _tokenCtrl.text = _tokenMask;
      _tokenMasked = true;
    }
    _successTplCtrl.text = cfg.successTemplate;
    _failureTplCtrl.text = cfg.failureTemplate;
    _tokenFocus.addListener(_onTokenFocusChange);
  }

  void _onTokenFocusChange() {
    if (_tokenFocus.hasFocus) {
      if (_tokenMasked) {
        setState(() {
          _tokenCtrl.clear();
          _tokenMasked = false;
        });
      }
    } else {
      // 失焦且没输入新值 → 恢复占位（token 仍是已保存的那个）。
      if (_tokenCtrl.text.trim().isEmpty && ref.read(slackConfigProvider).hasToken) {
        setState(() {
          _tokenCtrl.text = _tokenMask;
          _tokenMasked = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _tokenFocus.removeListener(_onTokenFocusChange);
    _tokenFocus.dispose();
    _tokenCtrl.dispose();
    _successTplCtrl.dispose();
    _failureTplCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final auth = await ref.read(slackNotifierProvider).checkConnection();
      if (!mounted) return;
      setState(() => _auth = auth);
    } catch (e) {
      if (!mounted) return;
      setState(() => _checkError = e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openRecipientPicker(List<SlackRecipient> current) async {
    final result = await showDialog<List<SlackRecipient>>(
      context: context,
      builder: (_) => _RecipientPickerDialog(initial: current),
    );
    if (result != null) {
      await ref.read(slackConfigProvider.notifier).setRecipients(result);
    }
  }

  Future<void> _saveToken() async {
    await ref.read(slackConfigProvider.notifier).saveToken(_tokenCtrl.text);
    if (!mounted) return;
    _tokenFocus.unfocus();
    setState(() {
      _tokenCtrl.text = _tokenMask;
      _tokenMasked = true;
      _auth = null;
      _checkError = null;
    });
    showTopToast(context, AppL10n.of(context).slackTokenSaved);
  }

  Future<void> _test() async {
    final l10n = AppL10n.of(context);
    final pool = ref.read(slackConfigProvider).recipients;
    if (pool.isEmpty) return;
    final picked = await showDialog<SlackRecipient>(
      context: context,
      builder: (_) => _TestRecipientDialog(pool: pool),
    );
    if (picked == null || !mounted) return;
    setState(() => _testing = true);
    try {
      await ref.read(slackNotifierProvider).sendTestTo(picked);
      if (!mounted) return;
      showTopToast(context, l10n.slackTestSent);
    } catch (e) {
      if (!mounted) return;
      showTopToast(context, l10n.slackTestFailed(e.toString()), isError: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 弹出占位符参考表：占位符 / 含义 / 示例值。
  Future<void> _showPlaceholderHelp() async {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final rows = <(String, String, String)>[
      ('{job}', l10n.slackPlaceholderJob, 'mcp-skills/next'),
      ('{number}', l10n.slackPlaceholderNumber, '114'),
      ('{result}', l10n.slackPlaceholderResult, l10n.slackPlaceholderResultExample),
      ('{emoji}', l10n.slackPlaceholderEmoji, '✅ / ❌'),
      ('{duration}', l10n.slackPlaceholderDuration, '4m49s'),
      ('{url}', l10n.slackPlaceholderUrl, 'https://…/job/…/114/'),
    ];

    TableRow headerRow() => TableRow(
          decoration: BoxDecoration(color: palette.surfaceRaised),
          children: [
            for (final h in [
              l10n.slackPlaceholderColToken,
              l10n.slackPlaceholderColMeaning,
              l10n.slackPlaceholderColExample,
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Text(h,
                    style: TextStyle(
                        color: palette.text,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        );

    TableRow dataRow(String token, String meaning, String example) => TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(token,
                  style: TextStyle(
                      color: palette.accent,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(meaning,
                  style: TextStyle(color: palette.text, fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(example,
                  style: TextStyle(color: palette.muted, fontSize: 12)),
            ),
          ],
        );

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.slackPlaceholderTitle),
        content: SingleChildScrollView(
          child: Table(
            border: TableBorder.all(
              color: palette.borderSubtle,
              borderRadius: BorderRadius.circular(6),
            ),
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: IntrinsicColumnWidth(),
              2: FlexColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              headerRow(),
              for (final r in rows) dataRow(r.$1, r.$2, r.$3),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  /// 单条消息模板编辑器：输入框 + 恢复默认按钮；随所属开关启用 / 置灰。
  Widget _templateField({
    required AppPalette palette,
    required String label,
    required String resetTip,
    required TextEditingController controller,
    required bool enabled,
    required ValueChanged<String> onChanged,
    required VoidCallback onReset,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 12.5),
              onChanged: onChanged,
              decoration: InputDecoration(
                isDense: true,
                labelText: label,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
          Tooltip(
            message: resetTip,
            child: IconButton(
              onPressed: enabled ? onReset : null,
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              color: palette.muted,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final cfg = ref.watch(slackConfigProvider);
    final ctrl = ref.read(slackConfigProvider.notifier);

    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(l10n.settingsSectionSlack),
      content: SizedBox(
        width: math.min(640, size.width - 80),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.settingsSlackHint,
                  style: TextStyle(color: palette.muted, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 8),
              // 配置引导
              Container(
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    dense: true,
                    initiallyExpanded: false,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    leading: Icon(Icons.help_outline_rounded, size: 16, color: palette.accent),
                    title: Text(l10n.slackGuideTitle,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: palette.text)),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(l10n.slackGuideBody,
                            style: TextStyle(color: palette.muted, fontSize: 11.5, height: 1.6)),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(l10n.slackScopesCopyLabel,
                            style: TextStyle(color: palette.muted, fontSize: 11)),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final s in _kSlackScopes) _ScopeChip(scope: s),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('https://api.slack.com/apps'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 14),
                          label: Text(l10n.slackOpenApps),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _slackGroupLabel(palette, l10n.slackGroupConnection),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: _StatusPill(
                  ok: cfg.hasToken,
                  text: cfg.hasToken ? l10n.slackConnected : l10n.slackNotConnected,
                ),
              ),
              const SizedBox(height: 10),
              // user token
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tokenCtrl,
                      focusNode: _tokenFocus,
                      obscureText: _tokenMasked ? false : _obscure,
                      style: const TextStyle(fontSize: 13),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: l10n.slackToken,
                        hintText: 'xoxp-…',
                        suffixIcon: _tokenMasked
                            ? null
                            : IconButton(
                                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 16),
                                onPressed: () => setState(() => _obscure = !_obscure),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_tokenMasked || _tokenCtrl.text.trim().isEmpty) ? null : _saveToken,
                    child: Text(l10n.settingsSave),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 权限检测
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: (_checking || !cfg.hasToken) ? null : _check,
                  icon: _checking
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.verified_user_outlined, size: 15),
                  label: Text(l10n.slackCheck),
                ),
              ),
              _buildCheckStatus(palette, l10n),
              const SizedBox(height: 18),
              // 候选发送人池(可搜索多选)
              _slackGroupLabel(palette, l10n.slackPoolLabel),
              const SizedBox(height: 4),
              Text(l10n.slackPoolHint,
                  style: TextStyle(color: palette.muted, fontSize: 11, height: 1.4)),
              const SizedBox(height: 8),
              if (cfg.recipients.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in cfg.recipients)
                      InputChip(
                        label: Text(
                          r.email.isNotEmpty ? '${r.label} · ${r.email}' : r.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () => ctrl.setRecipients(
                          cfg.recipients.where((x) => x.id != r.id).toList(),
                        ),
                      ),
                  ],
                )
              else
                Text(l10n.slackNoRecipients,
                    style: TextStyle(color: palette.muted, fontSize: 11.5)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: cfg.hasToken ? () => _openRecipientPicker(cfg.recipients) : null,
                  icon: const Icon(Icons.group_add_outlined, size: 15),
                  label: Text(l10n.slackPickRecipients),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _slackGroupLabel(palette, l10n.slackGroupTriggers),
                  ),
                  Tooltip(
                    message: l10n.slackPlaceholderTitle,
                    child: IconButton(
                      onPressed: _showPlaceholderHelp,
                      icon: const Icon(Icons.info_outline_rounded, size: 16),
                      color: palette.muted,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 28, height: 28),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(l10n.slackTemplateHint,
                  style: TextStyle(color: palette.muted, fontSize: 11, height: 1.4)),
              const SizedBox(height: 8),
              // 成功：开关 + 自定义模板
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: cfg.notifySuccess,
                onChanged: (v) => ctrl.setNotifySuccess(v ?? true),
                title: Text(l10n.slackNotifySuccess, style: const TextStyle(fontSize: 12.5)),
              ),
              _templateField(
                palette: palette,
                label: l10n.slackTemplateSuccessLabel,
                resetTip: l10n.slackTemplateReset,
                controller: _successTplCtrl,
                enabled: cfg.notifySuccess,
                onChanged: ctrl.setSuccessTemplate,
                onReset: () {
                  _successTplCtrl.text = kDefaultSlackSuccessTemplate;
                  ctrl.setSuccessTemplate(kDefaultSlackSuccessTemplate);
                },
              ),
              const SizedBox(height: 6),
              // 失败：开关 + 自定义模板
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: cfg.notifyFailure,
                onChanged: (v) => ctrl.setNotifyFailure(v ?? true),
                title: Text(l10n.slackNotifyFailure, style: const TextStyle(fontSize: 12.5)),
              ),
              _templateField(
                palette: palette,
                label: l10n.slackTemplateFailureLabel,
                resetTip: l10n.slackTemplateReset,
                controller: _failureTplCtrl,
                enabled: cfg.notifyFailure,
                onChanged: ctrl.setFailureTemplate,
                onReset: () {
                  _failureTplCtrl.text = kDefaultSlackFailureTemplate;
                  ctrl.setFailureTemplate(kDefaultSlackFailureTemplate);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: (_testing || !cfg.hasToken || cfg.recipients.isEmpty) ? null : _test,
          icon: _testing
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send_rounded, size: 15),
          label: Text(l10n.slackTest),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  Widget _buildCheckStatus(AppPalette palette, AppL10n l10n) {
    if (_checkError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(l10n.slackCheckFailed(_checkError!),
            style: TextStyle(color: palette.danger, fontSize: 11.5)),
      );
    }
    final auth = _auth;
    if (auth == null) return const SizedBox.shrink();
    if (!auth.ok) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(l10n.slackCheckFailed(slackErrorHint(auth.error)),
            style: TextStyle(color: palette.danger, fontSize: 11.5)),
      );
    }
    final missing = auth.missingScopes;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 13, color: palette.success),
              const SizedBox(width: 4),
              Flexible(
                child: Text(l10n.slackCheckedAs(auth.user ?? ''),
                    style: TextStyle(color: palette.muted, fontSize: 11.5)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          if (missing.isEmpty)
            Text(l10n.slackScopesOk,
                style: TextStyle(color: palette.success, fontSize: 11.5))
          else
            Text(l10n.slackMissingScopes(missing.join(', ')),
                style: TextStyle(color: palette.warning, fontSize: 11.5)),
        ],
      ),
    );
  }
}

/// 可搜索的多选接收人选择器:实时拉取 Slack 成员,勾选确定。
class _RecipientPickerDialog extends ConsumerStatefulWidget {
  const _RecipientPickerDialog({required this.initial});

  final List<SlackRecipient> initial;

  @override
  ConsumerState<_RecipientPickerDialog> createState() => _RecipientPickerDialogState();
}

class _RecipientPickerDialogState extends ConsumerState<_RecipientPickerDialog> {
  late Future<List<SlackRecipient>> _future;
  final _searchCtrl = TextEditingController();
  late final Map<String, SlackRecipient> _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = ref.read(slackNotifierProvider).fetchUsers();
    _selected = {for (final r in widget.initial) r.id: r};
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(l10n.slackPickRecipients)),
          IconButton(
            tooltip: l10n.commonRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: () => setState(() {
              _future = ref.read(slackNotifierProvider).fetchUsers(forceRefresh: true);
            }),
          ),
        ],
      ),
      content: SizedBox(
        width: math.min(460, size.width - 80),
        height: math.min(520, size.height - 160),
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: l10n.slackSearchUser,
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<SlackRecipient>>(
                future: _future,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.slackLoadUsersFailed(snap.error.toString()),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.danger, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => setState(() =>
                                _future = ref.read(slackNotifierProvider).fetchUsers(forceRefresh: true)),
                            child: Text(l10n.commonRetry),
                          ),
                        ],
                      ),
                    );
                  }
                  final all = snap.data ?? const <SlackRecipient>[];
                  final filtered = _query.isEmpty
                      ? all
                      : all
                          .where((r) =>
                              r.label.toLowerCase().contains(_query) ||
                              r.email.toLowerCase().contains(_query) ||
                              r.id.toLowerCase().contains(_query))
                          .toList();
                  // 没有任何邮箱 → 多半缺 users:read.email 权限,给个提示。
                  final noEmails = all.isNotEmpty && all.every((r) => r.email.isEmpty);
                  return Column(
                    children: [
                      if (noEmails)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline_rounded, size: 13, color: palette.warning),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  l10n.slackEmailScopeHint,
                                  style: TextStyle(color: palette.muted, fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(l10n.commonEmpty,
                                    style: TextStyle(color: palette.muted, fontSize: 12)),
                              )
                            : ListView.builder(
                                itemCount: filtered.length,
                                itemBuilder: (c, i) {
                                  final r = filtered[i];
                                  final sub = r.email.isNotEmpty ? r.email : r.id;
                                  return CheckboxListTile(
                                    dense: true,
                                    value: _selected.containsKey(r.id),
                                    title: Text(r.label, style: const TextStyle(fontSize: 13)),
                                    subtitle: Text(sub,
                                        style: TextStyle(color: palette.muted, fontSize: 10.5)),
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _selected[r.id] = r;
                                      } else {
                                        _selected.remove(r.id);
                                      }
                                    }),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
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
          onPressed: () => Navigator.pop(context, _selected.values.toList()),
          child: Text('${l10n.commonConfirm} (${_selected.length})'),
        ),
      ],
    );
  }
}

/// Slack user token 需要的 scopes（顺序即展示顺序）。
const _kSlackScopes = ['chat:write', 'im:write', 'users:read', 'users:read.email'];

/// 可点击复制的 scope 小标签。
class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: scope));
        if (!context.mounted) return;
        showTopToast(context, AppL10n.of(context).settingsCopiedToClipboard);
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              scope,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: palette.text,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, size: 12, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

/// 测试发送：从候选池里单选一个人。点条目即选中并返回。
class _TestRecipientDialog extends StatelessWidget {
  const _TestRecipientDialog({required this.pool});

  final List<SlackRecipient> pool;

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(l10n.slackTestPick),
      content: SizedBox(
        width: 360,
        height: (size.height * 0.5).clamp(200.0, 440.0),
        child: ListView.builder(
          itemCount: pool.length,
          itemBuilder: (c, i) {
            final r = pool[i];
            return ListTile(
              dense: true,
              leading: Icon(Icons.person_outline_rounded, size: 18, color: palette.muted),
              title: Text(r.label, style: const TextStyle(fontSize: 13)),
              subtitle: r.email.isNotEmpty
                  ? Text(r.email, style: TextStyle(color: palette.muted, fontSize: 10.5))
                  : null,
              onTap: () => Navigator.pop(context, r),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }
}

/// Slack 弹框里的小节标题（左侧加一条强调色竖条）。
Widget _slackGroupLabel(AppPalette palette, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: palette.text,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

/// 小状态药丸（已连接 / 未配置）。
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final c = ok ? palette.success : palette.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 11, color: c),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 构建结束通知开关。
///
/// 默认关闭；开启前必须先有系统通知权限。无权限时：开关无法打开，转而弹出
/// 引导，引导用户到系统设置授权。
class _NotificationsToggle extends ConsumerStatefulWidget {
  @override
  ConsumerState<_NotificationsToggle> createState() =>
      _NotificationsToggleState();
}

class _NotificationsToggleState extends ConsumerState<_NotificationsToggle> {
  /// null = 检测中；true / false = 是否已获得系统通知权限。
  bool? _permitted;

  @override
  void initState() {
    super.initState();
    _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final ok = await hasBuildNotificationPermission();
    if (mounted) setState(() => _permitted = ok);
  }

  Future<void> _onToggle(bool v) async {
    final ctrl = ref.read(notificationsEnabledProvider.notifier);
    if (!v) {
      // 关闭随时允许。
      await ctrl.setEnabled(false);
      return;
    }
    // 想开启：先确认（必要时请求）系统权限。
    var ok = await hasBuildNotificationPermission();
    if (!ok) ok = await requestBuildNotificationPermission();
    if (mounted) setState(() => _permitted = ok);
    if (ok) {
      await ctrl.setEnabled(true);
    } else if (mounted) {
      // 无权限：不开启，弹出引导配置。
      await _showPermissionGuide();
    }
  }

  Future<void> _showPermissionGuide() async {
    final l10n = AppL10n.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsNotificationsPermissionTitle),
        content: Text(l10n.settingsNotificationsPermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.settingsNotificationsOpenSettings),
          ),
        ],
      ),
    );
    if (go == true) {
      await openSystemNotificationSettings();
      // 用户从系统设置返回后，重新读一次权限状态。
      await _refreshPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final enabled = ref.watch(notificationsEnabledProvider);
    final permitted = _permitted;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            // 没有权限时视觉上保持关闭，并阻止通过开关直接打开。
            value: enabled && permitted != false,
            onChanged: _onToggle,
            title: Text(
              l10n.settingsNotificationsBuildResult,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsNotificationsHint,
              style: TextStyle(color: palette.muted, fontSize: 11.5, height: 1.35),
            ),
          ),
          if (permitted == false)
            Padding(
              padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 14, color: palette.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.settingsNotificationsNoPermission,
                      style: TextStyle(color: palette.warning, fontSize: 11.5, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, top: 2),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  if (permitted == false)
                    OutlinedButton.icon(
                      onPressed: _showPermissionGuide,
                      icon: const Icon(Icons.settings_outlined, size: 15),
                      label: Text(l10n.settingsNotificationsGuide),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await initBuildNotifications();
                      await showBuildResultNotification(
                        title: 'Deployment',
                        body: l10n.settingsNotificationsTestBody,
                      );
                      // 测试发送会暴露真实权限状态，顺手刷新一次。
                      await _refreshPermission();
                      if (!context.mounted) return;
                      showTopToast(context, l10n.settingsNotificationsTestSent);
                    },
                    icon: const Icon(Icons.notifications_active_outlined, size: 15),
                    label: Text(l10n.settingsNotificationsTest),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 章节标题：图标 + 加粗文本，所有设置分组共用，保证视觉一致。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Icon(icon, size: 16, color: palette.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: palette.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 可点击的章节条目：与 [_SectionHeader] 共用图标 + 标题样式；额外承载描述与可选 trailing。
class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: palette.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing!,
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: palette.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
