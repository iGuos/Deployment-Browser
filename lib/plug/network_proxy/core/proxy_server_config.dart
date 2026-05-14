/// 本应用内置转发代理（监听）参数；与 Jenkins 等业务无关。
class ProxyServerConfig {
  const ProxyServerConfig({
    this.listenOnLoopbackOnly = true,
    this.port = 0,
    this.listeningEnabled = false,
    this.encrypted = true,
    this.mitmEnabled = false,
    this.mitmRemoteClientsEnabled = false,
    this.proxyAllowHosts = const [],
    this.username = '',
    this.password = '',
  });

  /// `true` 时仅监听本机回环（127.0.0.1）；`false` 时监听 IPv4 任意地址（0.0.0.0）。
  final bool listenOnLoopbackOnly;

  /// 监听端口；`0` 表示未配置（不启动内置服务）。
  final int port;

  /// 是否实际启动监听（与 [NetworkProxyRole.server] 及合法 [port] 同时满足时才 bind）。
  final bool listeningEnabled;

  /// `true` 时监听 TLS 加密代理；`false` 时监听明文 HTTP 代理。
  final bool encrypted;

  /// `true` 时尝试对 CONNECT 后的 HTTPS 流量做调试级解密抓包。
  final bool mitmEnabled;

  /// `true` 时也对非本机客户端（如手机 / 局域网设备）做 HTTPS MITM。
  ///
  /// 默认关闭，避免未安装根证书的移动设备在开启解密后无法访问 HTTPS。
  final bool mitmRemoteClientsEnabled;

  /// 允许通过内置代理转发的目标主机名单。
  ///
  /// 为空表示全部允许；支持主机名或后缀匹配，如 `jenkins.example.com`、
  /// `.example.com`。这是服务端侧的 allowlist，用于限制手机/局域网客户端
  /// 哪些请求可以“走本代理”。
  final List<String> proxyAllowHosts;

  /// 代理 Basic 认证用户名和密码；服务端监听必须同时填写。
  final String username;
  final String password;

  bool get hasAuth => username.trim().isNotEmpty && password.isNotEmpty;

  static const ProxyServerConfig defaults = ProxyServerConfig();

  bool get isListenConfigured => port > 0 && port <= 65535;

  static List<String> parseProxyAllowHosts(String raw) {
    if (raw.trim().isEmpty) return const [];
    return raw
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
}
