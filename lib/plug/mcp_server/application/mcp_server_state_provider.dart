import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/preferences.dart';
import '../core/mcp_server_config.dart';
import '../core/mcp_server_state_codec.dart';

/// 内嵌 MCP 服务器配置（持久化于 [sharedPreferencesProvider]）。
///
/// 与网络代理不同：MCP 设置走应用内对话框（同一引擎/进程），无需跨窗口
/// reload 轮询，直接复用全局 SharedPreferences。
class McpServerConfigController extends Notifier<McpServerConfig> {
  @override
  McpServerConfig build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return McpServerStateCodec.decode(
      prefs.getString(McpServerStateCodec.preferenceKey),
    );
  }

  Future<void> persist(McpServerConfig value) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
      McpServerStateCodec.preferenceKey,
      McpServerStateCodec.encode(value),
    );
    state = value;
  }

  Future<void> update(
    McpServerConfig Function(McpServerConfig current) mutate,
  ) =>
      persist(mutate(state));
}

final mcpServerConfigProvider =
    NotifierProvider<McpServerConfigController, McpServerConfig>(
  McpServerConfigController.new,
);

/// 仅供宿主在启动时复用同一个 [SharedPreferences] 实例（保持与既有约定一致）。
final mcpServerSharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  return ref.watch(sharedPreferencesProvider);
});
