import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';

/// 启动期 Provider 观察者：把异常写到日志，便于诊断白屏 / 启动失败。
base class ProviderBootObserver extends ProviderObserver {
  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    appLogger.e(
      'Provider failed: ${context.provider.name ?? context.provider.runtimeType}',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
