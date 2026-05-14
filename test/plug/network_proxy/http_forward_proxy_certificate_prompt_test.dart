import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deployment/plug/network_proxy/http_client_proxy_apply.dart';
import 'package:deployment/plug/network_proxy/core/http_forward_proxy_server.dart';
import 'package:deployment/plug/network_proxy/proxy_client_config.dart';
import 'package:deployment/plug/network_proxy/core/proxy_network_event.dart';

void main() {
  test('shows mobile certificate prompt before proxy auth challenge', () async {
    final localAddress = await _firstNonLoopbackIpv4();
    if (localAddress == null) {
      markTestSkipped('No non-loopback IPv4 address available.');
      return;
    }

    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final server = HttpForwardProxyServer();
    await server.bind(
      address: InternetAddress.anyIPv4,
      port: port,
      encrypted: false,
      mitmEnabled: true,
      mitmRemoteClientsEnabled: true,
      authUsername: 'proxy',
      authPassword: 'secret',
    );
    addTearDown(server.close);

    final socket = await Socket.connect(
      localAddress,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.write(
      'GET http://example.com/ HTTP/1.1\r\n'
      'Host: example.com\r\n'
      '\r\n',
    );
    await socket.flush();

    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    await socket.close();

    expect(response, contains('HTTP/1.1 200 OK'));
    expect(response, contains('安装 HTTPS 解密根证书'));
    expect(response, isNot(contains('407 Proxy Authentication Required')));
  });

  test(
    'encrypted proxy returns certificate prompt for CONNECT before auth',
    () async {
      final localAddress = await _firstNonLoopbackIpv4();
      if (localAddress == null) {
        markTestSkipped('No non-loopback IPv4 address available.');
        return;
      }

      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      final server = HttpForwardProxyServer();
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

      final rawSocket = await Socket.connect(
        localAddress,
        port,
        timeout: const Duration(seconds: 3),
      );
      final socket = await SecureSocket.secure(
        rawSocket,
        host: 'deployment.proxy',
        onBadCertificate: (_) => true,
        supportedProtocols: const ['http/1.1'],
      );
      socket.write(
        'CONNECT example.com:443 HTTP/1.1\r\n'
        'Host: example.com:443\r\n'
        '\r\n',
      );
      await socket.flush();

      final response = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 5));
      await socket.close();

      expect(response, contains('HTTP/1.1 428 Certificate Required'));
      expect(response, contains('X-Deployment-Proxy-Certificate-Required: 1'));
      expect(response, contains('安装 HTTPS 解密根证书'));
      expect(response, isNot(contains('407 Proxy Authentication Required')));
    },
  );

  test('status reports whether MITM applies to this client', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final server = HttpForwardProxyServer();
    await server.bind(
      address: InternetAddress.loopbackIPv4,
      port: port,
      encrypted: false,
      mitmEnabled: true,
      mitmRemoteClientsEnabled: false,
      authUsername: 'proxy',
      authPassword: 'secret',
    );
    addTearDown(server.close);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.write(
      'GET /__proxy/status HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      '\r\n',
    );
    await socket.flush();

    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    await socket.close();

    expect(response, contains('"mitmEnabled":true'));
    expect(response, contains('"mitmRemoteClientsEnabled":false'));
    expect(response, contains('"mitmAppliesToClient":true'));
  });

  test('trust probe CONNECT bypasses proxy auth', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final server = HttpForwardProxyServer();
    await server.bind(
      address: InternetAddress.loopbackIPv4,
      port: port,
      encrypted: true,
      mitmEnabled: true,
      mitmRemoteClientsEnabled: false,
      proxyAllowHosts: const ['jenkins.example.com'],
      authUsername: 'proxy',
      authPassword: 'secret',
    );
    addTearDown(server.close);

    final rawSocket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    final socket = await SecureSocket.secure(
      rawSocket,
      host: 'deployment.proxy',
      onBadCertificate: (_) => true,
      supportedProtocols: const ['http/1.1'],
    );
    socket.write(
      'CONNECT ${HttpForwardProxyServer.mitmTrustProbeHost}:443 HTTP/1.1\r\n'
      'Host: ${HttpForwardProxyServer.mitmTrustProbeHost}:443\r\n'
      '\r\n',
    );
    await socket.flush();

    final response = await _readHeader(socket);
    await socket.close();

    expect(response, contains('HTTP/1.1 200 Connection Established'));
    expect(response, isNot(contains('407 Proxy Authentication Required')));
    expect(response, isNot(contains('403 Forbidden')));
    expect(response, isNot(contains('428 Certificate Required')));
  });

  test('encrypted proxy can complete MITM trust probe TLS', () async {
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();

    final server = HttpForwardProxyServer();
    await server.bind(
      address: InternetAddress.loopbackIPv4,
      port: port,
      encrypted: true,
      mitmEnabled: true,
      mitmRemoteClientsEnabled: false,
      authUsername: 'proxy',
      authPassword: 'secret',
    );
    addTearDown(server.close);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (_, _, _) => true;
    addTearDown(() => client.close(force: true));
    applyProxyClientToHttpClient(
      client,
      ProxyClientConfig(
        enabled: true,
        encrypted: true,
        host: InternetAddress.loopbackIPv4.address,
        port: port,
      ),
    );

    final req = await client
        .getUrl(
          Uri.https(
            HttpForwardProxyServer.mitmTrustProbeHost,
            '/__proxy/trust-check',
          ),
        )
        .timeout(const Duration(seconds: 5));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();

    expect(res.statusCode, 204);
  });

  test('response preview decodes gzip body', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    unawaited(
      upstream.forEach((request) async {
        final body = utf8.encode('{"message":"hello gzip preview"}');
        final compressed = gzip.encode(body);
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.headers.set(HttpHeaders.connectionHeader, 'close');
        request.response.contentLength = compressed.length;
        request.response.add(compressed);
        await request.response.close();
      }),
    );

    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();
    final events = <ProxyNetworkEvent>[];
    final server = HttpForwardProxyServer(onNetworkEvent: events.add);
    await server.bind(
      address: InternetAddress.loopbackIPv4,
      port: port,
      encrypted: false,
    );
    addTearDown(server.close);

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.write(
      'GET http://127.0.0.1:${upstream.port}/api HTTP/1.1\r\n'
      'Host: 127.0.0.1:${upstream.port}\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
    await socket.flush();
    await _readResponseByContentLength(socket);
    await socket.close();

    final preview = await _waitForCompletedPreview(events);
    expect(preview, contains('hello gzip preview'));
  });
}

Future<String> _readHeader(Socket socket) {
  final completer = Completer<String>();
  final bytes = <int>[];
  late final StreamSubscription<List<int>> sub;
  sub = socket.listen(
    (chunk) {
      bytes.addAll(chunk);
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.contains('\r\n\r\n') && !completer.isCompleted) {
        completer.complete(text.split('\r\n\r\n').first);
        unawaited(sub.cancel());
      }
    },
    onError: completer.completeError,
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(utf8.decode(bytes, allowMalformed: true));
      }
    },
  );
  return completer.future.timeout(const Duration(seconds: 5));
}

Future<List<int>> _readResponseByContentLength(Socket socket) {
  final completer = Completer<List<int>>();
  final bytes = <int>[];
  late final StreamSubscription<List<int>> sub;
  sub = socket.listen(
    (chunk) {
      bytes.addAll(chunk);
      final headerEnd = _headerEnd(bytes);
      if (headerEnd < 0) return;
      final headerText = utf8.decode(
        bytes.sublist(0, headerEnd - 4),
        allowMalformed: true,
      );
      final contentLength = _contentLength(headerText);
      if (contentLength == null) return;
      if (bytes.length >= headerEnd + contentLength && !completer.isCompleted) {
        completer.complete(List<int>.from(bytes));
        unawaited(sub.cancel());
      }
    },
    onError: completer.completeError,
    onDone: () {
      if (!completer.isCompleted) completer.complete(List<int>.from(bytes));
    },
  );
  return completer.future.timeout(const Duration(seconds: 5));
}

int _headerEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0x0d &&
        bytes[i + 1] == 0x0a &&
        bytes[i + 2] == 0x0d &&
        bytes[i + 3] == 0x0a) {
      return i + 4;
    }
  }
  return -1;
}

int? _contentLength(String headerText) {
  for (final line in headerText.split('\r\n').skip(1)) {
    final sep = line.indexOf(':');
    if (sep <= 0) continue;
    if (line.substring(0, sep).trim().toLowerCase() == 'content-length') {
      return int.tryParse(line.substring(sep + 1).trim());
    }
  }
  return null;
}

Future<String> _waitForCompletedPreview(List<ProxyNetworkEvent> events) async {
  for (var i = 0; i < 50; i++) {
    final previews = events
        .where((event) => event.kind == ProxyNetworkEventKind.completed)
        .map((event) => event.entry.responseBodyPreview)
        .where((text) => text.isNotEmpty)
        .toList();
    if (previews.isNotEmpty) return previews.last;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('No completed response preview event');
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
