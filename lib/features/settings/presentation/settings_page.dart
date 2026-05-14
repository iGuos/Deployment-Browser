import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/jenkins_http_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../application/network_proxy_state_provider.dart';
import '../data/jenkins_accounts_repository.dart';
import '../domain/jenkins_account.dart';
import '../domain/jenkins_config.dart';
import 'accounts_page.dart';

/// 设置页：编辑「当前激活账号」的连接信息。
///
/// - 多账号能力的入口（新增/切换/删除）在顶部账号 tab 栏的「管理账号」弹窗中；
/// - 这里只做单账号编辑器，便于熟悉旧 UI 的用户继续按以前的习惯使用。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();

  JenkinsAuthKind _kind = JenkinsAuthKind.token;
  bool _testing = false;
  bool _saving = false;
  String? _testError;
  String? _testInfo;

  /// 已经为哪个 accountId 填充过表单 — 切换账号时重置。
  String? _hydratedFor;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _userCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  void _hydrateFrom(JenkinsAccount? account) {
    final id = account?.id;
    if (_hydratedFor == id) return;
    _hydratedFor = id;
    _nameCtrl.text = account?.name ?? '';
    _baseUrlCtrl.text = account?.config.baseUrl ?? '';
    _userCtrl.text = account?.config.username ?? '';
    _secretCtrl.text = account?.config.secret ?? '';
    _kind = account?.config.authKind ?? JenkinsAuthKind.token;
    _testInfo = null;
    _testError = null;
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
      setState(() => _testInfo = '✓ ${AppL10n.of(context).settingsConnected}'
          '${res.version.isNotEmpty ? ' · ${res.version}' : ''}');
    } catch (e) {
      if (!mounted) return;
      final msg = e is JenkinsException ? e.message : e.toString();
      setState(() => _testError = msg);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _onSave(JenkinsAccount? current) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final cfg = _draftConfig();
      final id = current?.id ?? _generateAccountId(cfg);
      final name = _nameCtrl.text.trim().isEmpty ? cfg.displayHost : _nameCtrl.text.trim();
      final account = JenkinsAccount(id: id, name: name, config: cfg);
      final isNew = current == null;
      await ref.read(jenkinsAccountsProvider.notifier).upsert(account);
      if (isNew) {
        await ref.read(jenkinsAccountsProvider.notifier).setActive(account.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).settingsConnected)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).errorUnknown(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _generateAccountId(JenkinsConfig cfg) {
    final base =
        '${cfg.username}@${cfg.displayHost}'.replaceAll(RegExp(r'[^A-Za-z0-9_.@-]'), '_');
    return '$base-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppL10n.of(context).settingsCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onRemoveCurrent(JenkinsAccount account) async {
    await ref.read(jenkinsAccountsProvider.notifier).remove(account.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).accountsRemoved)),
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
        final current = s.activeAccount;
        _hydrateFrom(current);
        final isNew = current == null;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tune_rounded, color: palette.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.settingsTitle,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: palette.text,
                                ),
                              ),
                              if (current != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '${l10n.accountsActiveBadge} · ${current.displayName}',
                                    style: TextStyle(color: palette.muted, fontSize: 12),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.manage_accounts_outlined, size: 16),
                          label: Text(l10n.accountsManage),
                          onPressed: () => showAccountsManagerDialog(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _buildField(
                      label: l10n.accountsName,
                      hint: l10n.accountsNameHint,
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.label_outline_rounded, size: 18),
                        ),
                      ),
                    ),
                    _buildField(
                      label: l10n.settingsBaseUrl,
                      child: TextFormField(
                        controller: _baseUrlCtrl,
                        decoration: InputDecoration(
                          hintText: l10n.settingsBaseUrlHint,
                          prefixIcon: const Icon(Icons.link_rounded, size: 18),
                        ),
                        keyboardType: TextInputType.url,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) {
                          final t = v?.trim() ?? '';
                          if (t.isEmpty) return l10n.settingsRequiredAll;
                          if (!t.startsWith('http')) return 'URL 应以 http(s):// 开头';
                          return null;
                        },
                      ),
                    ),
                    _buildField(
                      label: l10n.settingsUsername,
                      hint: l10n.settingsUsernameHint,
                      child: TextFormField(
                        controller: _userCtrl,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
                        ),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) =>
                            (v?.trim().isEmpty ?? true) ? l10n.settingsRequiredAll : null,
                      ),
                    ),
                    _buildField(
                      label: l10n.settingsAuthKind,
                      child: SegmentedButton<JenkinsAuthKind>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: JenkinsAuthKind.password,
                            label: Text(l10n.settingsAuthPassword),
                            icon: const Icon(Icons.password_rounded, size: 16),
                          ),
                          ButtonSegment(
                            value: JenkinsAuthKind.token,
                            label: Text(l10n.settingsAuthToken),
                            icon: const Icon(Icons.vpn_key_rounded, size: 16),
                          ),
                        ],
                        selected: {_kind},
                        onSelectionChanged: (s) => setState(() => _kind = s.first),
                      ),
                    ),
                    _buildField(
                      label: _kind == JenkinsAuthKind.token
                          ? l10n.settingsSecretToken
                          : l10n.settingsSecretPassword,
                      hint: _kind == JenkinsAuthKind.token
                          ? l10n.settingsTokenHint
                          : l10n.settingsPasswordHint,
                      child: TextFormField(
                        controller: _secretCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.lock_outline_rounded, size: 18),
                        ),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) =>
                            (v?.isEmpty ?? true) ? l10n.settingsRequiredAll : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_testInfo != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Banner(
                          icon: Icons.check_circle_rounded,
                          color: palette.success,
                          text: _testInfo!,
                          onCopy: () => _copyToClipboard(_testInfo!),
                        ),
                      ),
                    if (_testError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Banner(
                          icon: Icons.error_rounded,
                          color: palette.danger,
                          text: l10n.settingsTestFailed(_testError!),
                          onCopy: () => _copyToClipboard(_testError!),
                        ),
                      ),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _testing ? null : _onTest,
                          icon: _testing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.bolt_rounded, size: 16),
                          label: Text(l10n.settingsTest),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _saving ? null : () => _onSave(current),
                          icon: _saving
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.save_rounded, size: 16),
                          label: Text(isNew ? l10n.accountsAddNew : l10n.settingsSave),
                        ),
                        const Spacer(),
                        if (_testError != null) ...[
                          TextButton.icon(
                            onPressed: () => _copyToClipboard(_testError!),
                            icon: const Icon(Icons.content_copy_rounded, size: 16),
                            label: Text(l10n.settingsCopyError),
                            style: TextButton.styleFrom(foregroundColor: palette.muted),
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (current != null)
                          TextButton.icon(
                            onPressed: () => _onRemoveCurrent(current),
                            icon: const Icon(Icons.delete_outline_rounded, size: 16),
                            label: Text(l10n.accountsRemove),
                            style: TextButton.styleFrom(foregroundColor: palette.danger),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _HelpCard(
                      title: l10n.settingsHelpTokenTitle,
                      body: l10n.settingsHelpTokenBody,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildField({required String label, String? hint, required Widget child}) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: palette.muted, fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          child,
          if (hint != null && hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(hint, style: TextStyle(color: palette.muted, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.text,
    this.onCopy,
  });

  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(color: palette.text, fontSize: 12.5, height: 1.45),
            ),
          ),
          if (onCopy != null)
            Tooltip(
              message: AppL10n.of(context).settingsCopyError,
              child: IconButton(
                onPressed: onCopy,
                icon: Icon(Icons.content_copy_rounded, size: 14, color: palette.muted),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                splashRadius: 14,
              ),
            ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.help_outline_rounded, size: 16, color: palette.info),
            const SizedBox(width: 6),
            Text(title, style: TextStyle(color: palette.text, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(color: palette.muted, fontSize: 12, height: 1.55)),
        ],
      ),
    );
  }
}
