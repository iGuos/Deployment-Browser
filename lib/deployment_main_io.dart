import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/notifications/build_notifier.dart';
import 'core/storage/preferences.dart';
import 'core/utils/app_logger.dart';
import 'core/utils/error_log_service.dart';
import 'core/utils/provider_boot_observer.dart';
import 'features/settings/presentation/proxy_settings_standalone_app.dart';
import 'features/settings/presentation/proxy_window_io.dart'
    show kProxyWindowArguments;
import 'plug/network_proxy/application/network_proxy_application.dart';
import 'plug/network_proxy/network_proxy.dart';

Future<void> deploymentMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();

  if (_isDesktopPlatform(defaultTargetPlatform)) {
    try {
      final wc = await WindowController.fromCurrentEngine();
      if (wc.arguments == kProxyWindowArguments) {
        // 子窗口由 desktop_multi_window 先创建在 (0,0)；在此用 window_manager 居中并收敛尺寸。
        try {
          await windowManager.ensureInitialized();
          const proxyOpts = WindowOptions(
            size: Size(720, 700),
            minimumSize: Size(520, 480),
            center: true,
            title: '代理设置',
            titleBarStyle: TitleBarStyle.normal,
            backgroundColor: Color(0xFF0F1115),
          );
          await windowManager.waitUntilReadyToShow(proxyOpts, () async {
            await windowManager.show();
            await windowManager.center();
            await windowManager.focus();
          });
        } catch (e, st) {
          appLogger.w('代理窗口居中/尺寸设置失败，仍打开界面', error: e, stackTrace: st);
        }
        runApp(const ProxySettingsStandaloneApp());
        return;
      }
      if (wc.arguments == kProxyLiveLogWindowArguments) {
        try {
          await windowManager.ensureInitialized();
          const logOpts = WindowOptions(
            size: Size(920, 560),
            minimumSize: Size(560, 360),
            center: true,
            title: '代理实时日志',
            titleBarStyle: TitleBarStyle.normal,
            backgroundColor: Color(0xFF0F1115),
          );
          await windowManager.waitUntilReadyToShow(logOpts, () async {
            await windowManager.show();
            await windowManager.center();
            await windowManager.focus();
          });
        } catch (e, st) {
          appLogger.w('代理实时日志窗口居中/尺寸设置失败，仍打开界面', error: e, stackTrace: st);
        }
        runApp(const ProxyLiveLogStandaloneApp());
        return;
      }
    } catch (e, st) {
      appLogger.w('多窗口入口检测失败，继续启动主程序', error: e, stackTrace: st);
    }
  }

  if (_isDesktopPlatform(defaultTargetPlatform)) {
    try {
      await windowManager.ensureInitialized();
      const opts = WindowOptions(
        size: Size(1280, 820),
        minimumSize: Size(880, 600),
        center: true,
        backgroundColor: Color(0xFF0F1115),
        titleBarStyle: TitleBarStyle.normal,
        title: 'Deployment',
      );
      await windowManager.waitUntilReadyToShow(opts, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e, st) {
      appLogger.w('窗口初始化失败，将继续以默认窗口启动', error: e, stackTrace: st);
    }
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  await errorLogService.bind(prefs);
  await _resetPersistedProxyListening(prefs);
  await initBuildNotifications();

  runApp(
    ProviderScope(
      observers: [ProviderBootObserver()],
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        networkProxySharedPreferencesProvider.overrideWithValue(prefs),
        networkProxyLoggerProvider.overrideWithValue((
          message, {
          error,
          stackTrace,
        }) {
          if (error != null || stackTrace != null) {
            appLogger.w(message, error: error, stackTrace: stackTrace);
          } else {
            appLogger.d(message);
          }
        }),
      ],
      child: const DeploymentApp(),
    ),
  );
}

/// 捕获 Flutter 框架与底层 Dart isolate 抛出的未处理异常，统一落入「异常日志」。
void _installGlobalErrorHandlers() {
  final priorFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    recordAppException(
      details.summary.toString(),
      error: details.exception,
      stackTrace: details.stack,
    );
    priorFlutterOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    recordAppException(
      'PlatformDispatcher uncaught error',
      error: error,
      stackTrace: stack,
    );
    return false; // 让默认处理继续生效。
  };
}

bool _isDesktopPlatform(TargetPlatform p) =>
    p == TargetPlatform.macOS ||
    p == TargetPlatform.windows ||
    p == TargetPlatform.linux;

Future<void> _resetPersistedProxyListening(SharedPreferences prefs) async {
  final state = NetworkProxyStateCodec.decode(
    prefs.getString(NetworkProxyStateCodec.preferenceKey),
  );
  if (!state.server.listeningEnabled) return;

  final next = NetworkProxyState(
    role: state.role,
    client: state.client,
    server: ProxyServerConfig(
      listenOnLoopbackOnly: state.server.listenOnLoopbackOnly,
      port: state.server.port,
      encrypted: state.server.encrypted,
      username: state.server.username,
      password: state.server.password,
      listeningEnabled: false,
    ),
  );
  await prefs.setString(
    NetworkProxyStateCodec.preferenceKey,
    NetworkProxyStateCodec.encode(next),
  );
}
