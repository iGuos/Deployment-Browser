import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'embedded_proxy_request_log_provider.dart';
import '../core/proxy_network_event.dart';

/// 独立代理设置引擎内注册；主进程在 [tryBroadcastEmbeddedProxyLogLine] 中投递原始日志行（与 [onLog] 字符串一致）。
Future<void> registerEmbeddedProxyLogCrossWindowReceiver({
  required bool Function() isMounted,
  required WidgetRef ref,
  Future<dynamic> Function(MethodCall call)? onUnhandledMethodCall,
}) async {
  final window = await WindowController.fromCurrentEngine();
  await window.setWindowMethodHandler((call) async {
    if (call.method == 'appendLog' && call.arguments is String) {
      if (!isMounted()) return null;
      ref
          .read(embeddedProxyRequestLogProvider.notifier)
          .addLine(call.arguments as String);
      return null;
    }
    if (call.method == 'appendNetworkEvent') {
      final event = ProxyNetworkEvent.fromJson(call.arguments);
      if (!isMounted() || event == null) return null;
      ref.read(embeddedProxyRequestLogProvider.notifier).applyEvent(event);
      return null;
    }
    return onUnhandledMethodCall?.call(call);
  });
}

Future<void> unregisterEmbeddedProxyLogCrossWindowReceiver() async {
  final window = await WindowController.fromCurrentEngine();
  await window.setWindowMethodHandler(null);
}

/// 主进程在写入本地 [embeddedProxyRequestLogProvider] 后调用；逐个子窗口投递，允许代理设置窗口和日志窗口同时接收。
void tryBroadcastEmbeddedProxyLogLine(String line) {
  unawaited(() async {
    try {
      final windows = await WindowController.getAll();
      await Future.wait(
        windows.map((w) async {
          try {
            await w.invokeMethod<void>('appendLog', line);
          } catch (_) {
            // 该窗口未注册日志 handler 或已经关闭，忽略。
          }
        }),
      );
    } on Object catch (_) {
      // 无子窗口、非桌面平台、插件未就绪等。
    }
  }());
}

void tryBroadcastEmbeddedProxyNetworkEvent(ProxyNetworkEvent event) {
  unawaited(() async {
    try {
      final windows = await WindowController.getAll();
      await Future.wait(
        windows.map((w) async {
          try {
            await w.invokeMethod<void>('appendNetworkEvent', event.toJson());
          } catch (_) {
            // 该窗口未注册 handler 或已经关闭，忽略。
          }
        }),
      );
    } on Object catch (_) {
      // 无子窗口、非桌面平台、插件未就绪等。
    }
  }());
}
