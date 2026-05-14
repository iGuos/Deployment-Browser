import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/locale/app_locale_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../l10n/app_localizations.dart';
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
              Text(
                l10n.settingsSectionMenu,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.settingsSectionMenuHint,
                style: TextStyle(color: palette.muted, fontSize: 12, height: 1.35),
              ),
              Divider(height: 24, color: palette.borderSubtle),
              Text(
                l10n.settingsSectionTheme,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ...ThemeMode.values.map(
                (m) => RadioListTile<ThemeMode>(
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
              Divider(height: 24, color: palette.borderSubtle),
              Text(
                l10n.settingsSectionLanguage,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              RadioListTile<Locale>(
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
              RadioListTile<Locale>(
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
              Divider(height: 24, color: palette.borderSubtle),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  l10n.settingsSectionProxy,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.settingsProxyOpenHint,
                    style: TextStyle(color: palette.muted, fontSize: 11.5),
                  ),
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  await openAppProxySettings(context: hostContext);
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
