import 'dart:convert';

import 'network_proxy_state.dart';
import 'proxy_client_config.dart';
import 'proxy_role.dart';
import 'proxy_server_config.dart';

/// JSON 编解码；不依赖 Flutter / SharedPreferences。
abstract final class NetworkProxyStateCodec {
  static const preferenceKey = 'plug.network_proxy.state_v1';

  static String encode(NetworkProxyState state) {
    return jsonEncode({
      'v': 1,
      'role': state.role.name,
      'client': {
        'enabled': state.client.enabled,
        'encrypted': state.client.encrypted,
        'host': state.client.host,
        'port': state.client.port,
        'username': state.client.username,
        'password': state.client.password,
        'noProxy': state.client.noProxyHosts,
      },
      'server': {
        'bind': state.server.listenOnLoopbackOnly ? 'loopback' : 'any',
        'port': state.server.port,
        'listeningEnabled': state.server.listeningEnabled,
        'encrypted': state.server.encrypted,
        'mitmEnabled': state.server.mitmEnabled,
        'mitmRemoteClientsEnabled': state.server.mitmRemoteClientsEnabled,
        'proxyAllowHosts': state.server.proxyAllowHosts,
        'username': state.server.username,
        'password': state.server.password,
      },
    });
  }

  static NetworkProxyState decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return NetworkProxyState.defaults;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>?;
      if (m == null) return NetworkProxyState.defaults;
      final roleStr = m['role'] as String? ?? 'client';
      final role = switch (roleStr) {
        'server' => NetworkProxyRole.server,
        _ => NetworkProxyRole.client,
      };
      final c = m['client'];
      final server = _decodeServer(m['server']);
      if (c is! Map<String, dynamic>) {
        return NetworkProxyState(
          role: role,
          client: ProxyClientConfig.disabled,
          server: server,
        );
      }
      final no = c['noProxy'];
      final noList = no is List
          ? no.map((e) => e.toString()).toList(growable: false)
          : ProxyClientConfig.parseNoProxyList(no?.toString() ?? '');
      return NetworkProxyState(
        role: role,
        client: ProxyClientConfig(
          enabled: c['enabled'] as bool? ?? false,
          encrypted: c['encrypted'] as bool? ?? true,
          host: (c['host'] as String?) ?? '',
          port: (c['port'] as num?)?.toInt() ?? 0,
          username: (c['username'] as String?) ?? '',
          password: (c['password'] as String?) ?? '',
          noProxyHosts: noList,
        ),
        server: server,
      );
    } catch (_) {
      return NetworkProxyState.defaults;
    }
  }

  static ProxyServerConfig _decodeServer(Object? raw) {
    if (raw is! Map<String, dynamic>) return ProxyServerConfig.defaults;
    final bind = raw['bind'] as String? ?? 'loopback';
    final port = (raw['port'] as num?)?.toInt() ?? 0;
    final le = raw['listeningEnabled'];
    final bool listeningEnabled;
    if (le is bool) {
      listeningEnabled = le;
    } else {
      // 旧 JSON 无该字段：有合法端口时视为已开启监听，避免升级后行为突变。
      listeningEnabled = port > 0 && port <= 65535;
    }
    return ProxyServerConfig(
      listenOnLoopbackOnly: bind != 'any',
      port: port,
      listeningEnabled: listeningEnabled,
      encrypted: raw['encrypted'] as bool? ?? true,
      mitmEnabled: raw['mitmEnabled'] as bool? ?? false,
      mitmRemoteClientsEnabled:
          raw['mitmRemoteClientsEnabled'] as bool? ?? false,
      proxyAllowHosts: _decodeStringList(raw['proxyAllowHosts']),
      username: raw['username'] as String? ?? '',
      password: raw['password'] as String? ?? '',
    );
  }

  static List<String> _decodeStringList(Object? raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).toList(growable: false);
    }
    return ProxyServerConfig.parseProxyAllowHosts(raw?.toString() ?? '');
  }
}
