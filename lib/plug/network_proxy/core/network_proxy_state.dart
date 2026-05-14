import 'proxy_client_config.dart';
import 'proxy_role.dart';
import 'proxy_server_config.dart';

/// 持久化的代理模式 + 客户端参数 + 内置服务端监听参数（无业务字段）。
class NetworkProxyState {
  const NetworkProxyState({
    required this.role,
    required this.client,
    this.server = ProxyServerConfig.defaults,
  });

  final NetworkProxyRole role;
  final ProxyClientConfig client;

  /// 内置转发代理监听配置（与 [NetworkProxyRole.server] 配合使用）。
  final ProxyServerConfig server;

  static const NetworkProxyState defaults = NetworkProxyState(
    role: NetworkProxyRole.client,
    client: ProxyClientConfig.disabled,
    server: ProxyServerConfig.defaults,
  );

  /// 仅当角色为客户端且客户端配置有效时，才应对 HttpClient 应用代理。
  bool get shouldUseClientProxy =>
      role == NetworkProxyRole.client && client.isConfigured;

  /// 是否应在当前进程启动内置转发代理（CONNECT / 基础 http 绝对 URI）。
  bool get shouldRunEmbeddedProxyServer =>
      role == NetworkProxyRole.server &&
      server.listeningEnabled &&
      server.isListenConfigured &&
      server.hasAuth;
}
