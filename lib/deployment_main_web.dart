import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/storage/preferences.dart';
import 'core/utils/error_log_service.dart';
import 'core/utils/provider_boot_observer.dart';

Future<void> deploymentMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  await errorLogService.bind(prefs);

  runApp(
    ProviderScope(
      observers: [ProviderBootObserver()],
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
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
    return false;
  };
}
