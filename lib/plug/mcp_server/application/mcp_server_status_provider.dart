import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 内嵌 MCP 服务器的实时运行状态，供设置面板显示「监听中 / 未运行 / 绑定失败」。
@immutable
class McpServerStatus {
  const McpServerStatus({
    this.listening = false,
    this.port,
    this.loopbackOnly = true,
    this.error,
  });

  /// 是否已成功开始监听。
  final bool listening;

  /// 当前（尝试）监听的端口。
  final int? port;

  final bool loopbackOnly;

  /// 最近一次绑定失败的原因；null 表示无错误。
  final String? error;

  bool get hasError => error != null;

  static const McpServerStatus stopped = McpServerStatus();
}

class McpServerStatusNotifier extends Notifier<McpServerStatus> {
  @override
  McpServerStatus build() => McpServerStatus.stopped;

  void setListening({required int port, required bool loopbackOnly}) {
    state = McpServerStatus(
      listening: true,
      port: port,
      loopbackOnly: loopbackOnly,
    );
  }

  void setStopped() => state = McpServerStatus.stopped;

  void setError({required int port, required bool loopbackOnly, required String error}) {
    state = McpServerStatus(
      listening: false,
      port: port,
      loopbackOnly: loopbackOnly,
      error: error,
    );
  }
}

final mcpServerStatusProvider =
    NotifierProvider<McpServerStatusNotifier, McpServerStatus>(
  McpServerStatusNotifier.new,
);
