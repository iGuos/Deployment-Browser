import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/locale/app_locale_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/error_log_service.dart';
import '../../../l10n/app_localizations.dart';
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

    return AlertDialog(
      title: Text(l10n.settingsDialogTitle),
      content: SizedBox(
        width: 440,
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
              ...ThemeMode.values.map(
                (m) => Padding(
                  padding: const EdgeInsets.only(left: 18),
                  child: RadioListTile<ThemeMode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: m,
                    groupValue: themeMode,
                    title: Text(
                      switch (m) {
                        ThemeMode.system => l10n.themeFollowSystem,
                        ThemeMode.dark => l10n.themeDark,
                        ThemeMode.light => l10n.themeLight,
                      },
                      style: const TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) {
                      if (v == null) return;
                      ref.read(themeModeProvider.notifier).setMode(v);
                    },
                  ),
                ),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              _SectionHeader(
                icon: Icons.translate_rounded,
                title: l10n.settingsSectionLanguage,
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: RadioListTile<Locale>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: const Locale('zh'),
                  groupValue: locale,
                  title: Text(l10n.settingsLanguageZh, style: const TextStyle(fontSize: 13)),
                  onChanged: (v) {
                    if (v == null) return;
                    ref.read(appLocaleProvider.notifier).setLocale(v);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: RadioListTile<Locale>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: const Locale('en'),
                  groupValue: locale,
                  title: Text(l10n.settingsLanguageEn, style: const TextStyle(fontSize: 13)),
                  onChanged: (v) {
                    if (v == null) return;
                    ref.read(appLocaleProvider.notifier).setLocale(v);
                  },
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
