/// 客户端走上游 HTTP 代理时的配置（不含 Jenkins 等业务字段）。
class ProxyClientConfig {
  const ProxyClientConfig({
    required this.enabled,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
    this.noProxyHosts = const [],
    this.encrypted = true,
  });

  /// 关闭时等价于直连（仍可与 [NetworkProxyRole.client] 并存，由上层决定是否忽略）。
  final bool enabled;

  /// `true` 时用 TLS 加密连接上游代理；`false` 时用明文 HTTP 代理。
  final bool encrypted;

  /// 代理主机名或 IP（不含 scheme）。
  final String host;

  final int port;

  final String username;
  final String password;

  /// 直连名单：主机名或后缀（如 `localhost`、`127.0.0.1`、`.local`），逗号分隔解析由 [parseNoProxyList] 完成。
  final List<String> noProxyHosts;

  static const ProxyClientConfig disabled = ProxyClientConfig(enabled: false);

  bool get isConfigured =>
      enabled && host.trim().isNotEmpty && port > 0 && port <= 65535;

  /// `no_proxy` 风格：逗号/空白分隔。
  static List<String> parseNoProxyList(String raw) {
    if (raw.trim().isEmpty) return const [];
    return raw
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  bool shouldBypassHost(String targetHost) {
    final host = targetHost.toLowerCase();
    for (final pattern in noProxyHosts) {
      final p = pattern.trim().toLowerCase();
      if (p.isEmpty) continue;
      if (p.startsWith('.')) {
        if (host.endsWith(p) || host == p.substring(1)) return true;
      } else if (host == p || host.endsWith('.$p')) {
        return true;
      }
    }
    return false;
  }
}
