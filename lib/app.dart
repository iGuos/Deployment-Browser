import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/locale/app_locale_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/settings/application/network_proxy_embedded_server_binding.dart';
import 'features/settings/application/network_proxy_state_provider.dart';
import 'features/workspace/presentation/workspace_shell.dart';
import 'l10n/app_localizations.dart';

class DeploymentApp extends ConsumerStatefulWidget {
  const DeploymentApp({super.key});

  @override
  ConsumerState<DeploymentApp> createState() => _DeploymentAppState();
}

class _DeploymentAppState extends ConsumerState<DeploymentApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(networkProxyStateProvider.notifier).reloadFromDisk());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(networkProxyEmbeddedServerBindingProvider);
    final mode = ref.watch(themeModeProvider);
    final locale = ref.watch(appLocaleProvider);
    return MaterialApp(
      title: 'Deployment',
      debugShowCheckedModeBanner: false,
      locale: locale,
      themeMode: mode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: const WorkspaceShell(),
      builder: (ctx, child) => MediaQuery(
        // 限制系统字号缩放，避免桌面端 UI 错乱
        data: MediaQuery.of(ctx).copyWith(
          textScaler: MediaQuery.textScalerOf(ctx).clamp(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.2,
          ),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
