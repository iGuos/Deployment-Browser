import 'dart:convert';

import 'mcp_server_config.dart';
import 'mcp_token.dart';

/// [McpServerConfig] 的 JSON 编解码；不依赖 Flutter / SharedPreferences。
abstract final class McpServerStateCodec {
  static const preferenceKey = 'plug.mcp_server.state_v1';

  static String encode(McpServerConfig config) {
    return jsonEncode({
      'v': 1,
      'enabled': config.enabled,
      'bind': config.listenOnLoopbackOnly ? 'loopback' : 'any',
      'port': config.port,
      'tokens': config.tokens.map((t) => t.toJson()).toList(growable: false),
    });
  }

  static McpServerConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return McpServerConfig.defaults;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>?;
      if (m == null) return McpServerConfig.defaults;
      final tokensRaw = m['tokens'];
      final tokens = tokensRaw is List
          ? tokensRaw
              .whereType<Map<String, dynamic>>()
              .map(McpToken.fromJson)
              .where((t) => t.id.isNotEmpty && t.secret.isNotEmpty)
              .toList(growable: false)
          : const <McpToken>[];
      return McpServerConfig(
        enabled: m['enabled'] as bool? ?? false,
        listenOnLoopbackOnly: (m['bind'] as String? ?? 'loopback') != 'any',
        port: (m['port'] as num?)?.toInt() ?? 0,
        tokens: tokens,
      );
    } catch (_) {
      return McpServerConfig.defaults;
    }
  }
}
