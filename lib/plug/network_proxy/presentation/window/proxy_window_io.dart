import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../proxy_settings_standalone_app.dart'
    show NetworkProxyPresentationLabels, ProxySettingsFormPage;

const kProxyWindowArguments = 'app_proxy_settings';

Future<void>? _openProxySettingsWindowTask;
bool _embeddedProxySettingsDialogOpen = false;

Future<void> openNetworkProxySettings({BuildContext? context}) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      final running = _openProxySettingsWindowTask;
      if (running != null) return running;
      final task = _openOrFocusProxySettingsWindow(context: context);
      _openProxySettingsWindowTask = task;
      try {
        await task;
      } finally {
        _openProxySettingsWindowTask = null;
      }
      return;
    default:
      if (context != null && context.mounted) {
        await _openProxySettingsEmbeddedDialog(context);
      }
  }
}

Future<void> _openOrFocusProxySettingsWindow({BuildContext? context}) async {
  try {
    final existing = await _findProxySettingsWindow();
    if (existing != null) {
      await _showExistingProxySettingsWindow(existing);
      return;
    }
    final w = await WindowController.create(
      const WindowConfiguration(
        arguments: kProxyWindowArguments,
        hiddenAtLaunch: true,
      ),
    );
    await w.show();
  } catch (e, st) {
    debugPrint('打开代理设置窗口失败: $e\n$st');
    if (context != null && context.mounted) {
      await _openProxySettingsEmbeddedDialog(context);
    }
  }
}

Future<void> openAppProxySettings({BuildContext? context}) {
  return openNetworkProxySettings(context: context);
}

Future<WindowController?> _findProxySettingsWindow() async {
  final windows = await WindowController.getAll();
  for (final window in windows) {
    if (window.arguments == kProxyWindowArguments) return window;
  }
  return null;
}

Future<void> _showExistingProxySettingsWindow(WindowController window) async {
  try {
    await window.invokeMethod<void>('showAndFocus');
  } catch (_) {
    await window.show();
  }
}

/// 移动端等无独立代理窗口时：在主窗口内弹出完整表单（客户端 / 服务端，与独立窗口一致）。
Future<void> _openProxySettingsEmbeddedDialog(BuildContext context) async {
  if (_embeddedProxySettingsDialogOpen) return;
  _embeddedProxySettingsDialogOpen = true;
  final labels = NetworkProxyPresentationLabels.of(context);
  final h = MediaQuery.sizeOf(context).height;
  try {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final w = MediaQuery.sizeOf(ctx).width;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 20,
          ),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SizedBox(
            width: math.min(560, w - 24),
            height: h * 0.88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          labels.settingsSectionProxy,
                          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: MaterialLocalizations.of(ctx).closeButtonLabel,
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Material(
                    color: Theme.of(ctx).colorScheme.surface,
                    child: const ProxySettingsFormPage(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  } finally {
    _embeddedProxySettingsDialogOpen = false;
  }
}
