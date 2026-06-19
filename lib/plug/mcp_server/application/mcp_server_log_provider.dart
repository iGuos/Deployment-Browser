import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 内嵌 MCP 服务器的近期日志（环形缓冲），供设置面板查看启停与调用情况。
class McpServerLogNotifier extends Notifier<List<String>> {
  static const _maxLines = 300;

  @override
  List<String> build() => const [];

  void add(String line) {
    final stamped = line.trim();
    if (stamped.isEmpty) return;
    final next = [...state, stamped];
    if (next.length > _maxLines) {
      next.removeRange(0, next.length - _maxLines);
    }
    state = next;
  }

  void clear() => state = const [];
}

final mcpServerLogProvider =
    NotifierProvider<McpServerLogNotifier, List<String>>(
  McpServerLogNotifier.new,
);
