import 'dart:convert';
import 'dart:io';

import 'http_client_proxy_apply.dart';
import 'http_forward_proxy_server.dart';
import 'network_proxy_state.dart';
import 'proxy_certificate_probe_result.dart';

Future<ProxyCertificateProbeResult> probeProxyCertificateStatus(
  NetworkProxyState state,
) async {
  final proxy = state.client;
  if (!state.shouldUseClientProxy || !proxy.isConfigured) {
    return const ProxyCertificateProbeResult(
      proxyReachable: false,
      certificateRequired: false,
      certificateTrusted: true,
      installUrl: null,
    );
  }

  final scheme = proxy.encrypted ? 'https' : 'http';
  final installUrl = '$scheme://${proxy.host}:${proxy.port}/__proxy/cert';
  try {
    final status = await _fetchProxyStatus(state);
    final mitmAppliesToClient = status['mitmAppliesToClient'] == true;
    if (!mitmAppliesToClient) {
      return ProxyCertificateProbeResult(
        proxyReachable: true,
        certificateRequired: false,
        certificateTrusted: true,
        installUrl: installUrl,
        status: status,
      );
    }

    final trusted = await _probeMitmCertificateTrust(state);
    return ProxyCertificateProbeResult(
      proxyReachable: true,
      certificateRequired: !trusted,
      certificateTrusted: trusted,
      installUrl: installUrl,
      status: status,
    );
  } catch (e) {
    return ProxyCertificateProbeResult(
      proxyReachable: false,
      certificateRequired: false,
      certificateTrusted: true,
      installUrl: installUrl,
      error: e,
    );
  }
}

Future<Map<String, Object?>> _fetchProxyStatus(NetworkProxyState state) async {
  final proxy = state.client;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..badCertificateCallback = (_, _, _) => true;
  try {
    final scheme = proxy.encrypted ? 'https' : 'http';
    final uri = Uri.parse(
      '$scheme://${proxy.host}:${proxy.port}/__proxy/status',
    );
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 5));
    final res = await req.close().timeout(const Duration(seconds: 5));
    final body = await utf8.decoder.bind(res).join();
    if (res.statusCode != 200) {
      throw HttpException('Proxy status failed (${res.statusCode})', uri: uri);
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const FormatException('Proxy status is not an object');
  } finally {
    client.close(force: true);
  }
}

Future<bool> _probeMitmCertificateTrust(NetworkProxyState state) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  applyProxyClientToHttpClient(client, state.client);
  try {
    final uri = Uri.https(
      HttpForwardProxyServer.mitmTrustProbeHost,
      '/__proxy/trust-check',
    );
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 5));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
    return res.statusCode == 204;
  } on HandshakeException {
    return false;
  } on HttpException catch (e) {
    final text = e.toString();
    if (text.contains('428 Certificate Required') ||
        text.contains('CERTIFICATE') ||
        text.contains('certificate')) {
      return false;
    }
    rethrow;
  } on TlsException {
    return false;
  } finally {
    client.close(force: true);
  }
}
