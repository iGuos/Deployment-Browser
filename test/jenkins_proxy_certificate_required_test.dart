import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deployment/core/http/jenkins_http_client.dart';
import 'package:deployment/plug/network_proxy/http_forward_proxy_server.dart';
import 'package:deployment/plug/network_proxy/mitm_certificate_manager.dart';
import 'package:deployment/plug/network_proxy/network_proxy.dart';

void main() {
  test(
    'maps encrypted proxy certificate requirement to JenkinsException',
    () async {
      final localAddress = await _firstNonLoopbackIpv4();
      if (localAddress == null) {
        markTestSkipped('No non-loopback IPv4 address available.');
        return;
      }

      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();
      final certDir = await Directory.systemTemp.createTemp(
        'deployment_mitm_probe_test_',
      );
      addTearDown(() async {
        if (await certDir.exists()) await certDir.delete(recursive: true);
      });

      final server = HttpForwardProxyServer(
        mitmCertificateManager: MitmCertificateManager(baseDirectory: certDir),
      );
      await server.bind(
        address: InternetAddress.anyIPv4,
        port: port,
        encrypted: true,
        mitmEnabled: true,
        mitmRemoteClientsEnabled: true,
        authUsername: 'proxy',
        authPassword: 'secret',
      );
      addTearDown(server.close);

      final dio = buildJenkinsDio(
        baseUrl: 'https://example.com',
        credentials: const JenkinsCredentials(
          username: 'jenkins',
          secret: 'token',
          kind: JenkinsAuthKind.token,
        ),
        networkProxy: NetworkProxyState(
          role: NetworkProxyRole.client,
          client: ProxyClientConfig(
            enabled: true,
            encrypted: true,
            host: localAddress.address,
            port: port,
            username: 'proxy',
            password: 'secret',
          ),
        ),
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        sendTimeout: const Duration(seconds: 3),
      );
      addTearDown(() => dio.close(force: true));

      Object? caught;
      try {
        await dio.get<Map<String, dynamic>>('/api/json');
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<DioException>());
      final mapped = toJenkinsException(caught!);
      expect(mapped.statusCode, 428);
      expect(mapped.proxyCertificateRequired, isTrue);
      expect(mapped.message, contains('根证书'));
    },
  );

  test(
    'polls encrypted proxy status and detects untrusted certificate',
    () async {
      final localAddress = await _firstNonLoopbackIpv4();
      if (localAddress == null) {
        markTestSkipped('No non-loopback IPv4 address available.');
        return;
      }

      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();
      final certDir = await Directory.systemTemp.createTemp(
        'deployment_mitm_probe_test_',
      );
      addTearDown(() async {
        if (await certDir.exists()) await certDir.delete(recursive: true);
      });

      final server = HttpForwardProxyServer(
        mitmCertificateManager: MitmCertificateManager(baseDirectory: certDir),
      );
      await server.bind(
        address: InternetAddress.anyIPv4,
        port: port,
        encrypted: true,
        mitmEnabled: true,
        mitmRemoteClientsEnabled: true,
        authUsername: 'proxy',
        authPassword: 'secret',
      );
      addTearDown(server.close);

      final result = await probeProxyCertificateStatus(
        NetworkProxyState(
          role: NetworkProxyRole.client,
          client: ProxyClientConfig(
            enabled: true,
            encrypted: true,
            host: localAddress.address,
            port: port,
            username: 'proxy',
            password: 'secret',
          ),
        ),
      );

      expect(result.proxyReachable, isTrue);
      expect(result.certificateRequired, isTrue);
      expect(result.certificateTrusted, isFalse);
      expect(result.installUrl, startsWith('https://${localAddress.address}:'));
    },
  );
}

Future<InternetAddress?> _firstNonLoopbackIpv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address;
    }
  }
  return null;
}
