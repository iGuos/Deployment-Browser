import 'package:deployment/plug/network_proxy/core/network_proxy_state.dart';
import 'package:deployment/plug/network_proxy/core/network_proxy_state_codec.dart';
import 'package:deployment/plug/network_proxy/proxy_client_config.dart';
import 'package:deployment/plug/network_proxy/proxy_role.dart';
import 'package:deployment/plug/network_proxy/proxy_server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes and decodes server proxy allow hosts', () {
    const state = NetworkProxyState(
      role: NetworkProxyRole.server,
      client: ProxyClientConfig.disabled,
      server: ProxyServerConfig(
        listenOnLoopbackOnly: false,
        port: 8888,
        listeningEnabled: true,
        encrypted: false,
        mitmEnabled: true,
        mitmRemoteClientsEnabled: true,
        proxyAllowHosts: ['jenkins.example.com', '.corp.local'],
        username: 'u',
        password: 'p',
      ),
    );

    final decoded = NetworkProxyStateCodec.decode(
      NetworkProxyStateCodec.encode(state),
    );

    expect(decoded.server.proxyAllowHosts, [
      'jenkins.example.com',
      '.corp.local',
    ]);
    expect(decoded.server.mitmRemoteClientsEnabled, isTrue);
  });
}
