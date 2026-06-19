import 'package:flutter/foundation.dart';

import 'mcp_token.dart';

/// 内置 MCP 接口服务器配置（监听开关、绑定范围、端口、访问令牌）。
@immutable
class McpServerConfig {
  const McpServerConfig({
    this.enabled = false,
    this.listenOnLoopbackOnly = true,
    this.port = 0,
    this.tokens = const [],
  });

  /// 是否开启对外 MCP 接口。
  final bool enabled;

  /// `true` 仅监听本机回环（127.0.0.1）；`false` 监听 IPv4 任意地址（0.0.0.0，局域网可达）。
  final bool listenOnLoopbackOnly;

  /// 监听端口；`0` 表示未配置。
  final int port;

  /// 访问令牌列表；为空时所有请求都会被拒绝（接口实际不可用）。
  final List<McpToken> tokens;

  bool get isListenConfigured => port > 0 && port <= 65535;

  /// 同时满足「已开启」+「端口合法」才真正 bind。
  bool get shouldRun => enabled && isListenConfigured;

  static const McpServerConfig defaults = McpServerConfig();

  /// 按明文令牌串查找匹配的 token id；找不到返回 null。
  String? tokenIdForSecret(String? presented) {
    final s = presented?.trim() ?? '';
    if (s.isEmpty) return null;
    for (final t in tokens) {
      if (t.secret.isNotEmpty && t.secret == s) return t.id;
    }
    return null;
  }

  McpToken? tokenById(String id) {
    for (final t in tokens) {
      if (t.id == id) return t;
    }
    return null;
  }

  McpServerConfig copyWith({
    bool? enabled,
    bool? listenOnLoopbackOnly,
    int? port,
    List<McpToken>? tokens,
  }) {
    return McpServerConfig(
      enabled: enabled ?? this.enabled,
      listenOnLoopbackOnly: listenOnLoopbackOnly ?? this.listenOnLoopbackOnly,
      port: port ?? this.port,
      tokens: tokens ?? this.tokens,
    );
  }
}
