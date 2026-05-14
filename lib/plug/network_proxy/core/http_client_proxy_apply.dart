import 'dart:io';

import 'proxy_client_config.dart';

/// 将 [ProxyClientConfig] 应用到 [HttpClient]（仅客户端代理语义）。
///
/// 不包含任何业务 URL 规则；[ProxyClientConfig.shouldBypassHost] 仅按主机名匹配。
/// 代理连接按 [ProxyClientConfig.encrypted] 选择 TLS 加密或明文 HTTP 代理。
void applyProxyClientToHttpClient(HttpClient client, ProxyClientConfig config) {
  if (!config.isConfigured) {
    client.findProxy = null;
    client.authenticateProxy = null;
    client.connectionFactory = null;
    return;
  }

  final host = config.host.trim();
  final port = config.port;
  final hasCreds = config.username.isNotEmpty || config.password.isNotEmpty;

  client.findProxy = (uri) {
    final targetHost = uri.host;
    if (config.shouldBypassHost(targetHost)) {
      return 'DIRECT';
    }
    return 'PROXY $host:$port';
  };

  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost == null || proxyPort == null) {
      return Socket.startConnect(uri.host, uri.port);
    }

    if (config.encrypted) {
      final secureTask = await SecureSocket.startConnect(
        proxyHost,
        proxyPort,
        onBadCertificate: (_) => true,
        supportedProtocols: const ['http/1.1'],
      );
      return ConnectionTask.fromSocket<Socket>(
        secureTask.socket,
        secureTask.cancel,
      );
    }

    return Socket.startConnect(proxyHost, proxyPort);
  };

  if (hasCreds) {
    client.authenticateProxy = (proxyHost, proxyPort, scheme, realm) async {
      client.addProxyCredentials(
        proxyHost,
        proxyPort,
        realm ?? '',
        HttpClientBasicCredentials(config.username, config.password),
      );
      return true;
    };
  } else {
    client.authenticateProxy = null;
  }
}
