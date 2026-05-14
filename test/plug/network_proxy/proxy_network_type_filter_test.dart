import 'package:deployment/plug/network_proxy/application/embedded_proxy_request_log_provider.dart';
import 'package:deployment/plug/network_proxy/core/proxy_network_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies common DevTools network resource types', () {
    expect(proxyNetworkDevToolsType(_entry('/app.css')), 'CSS');
    expect(proxyNetworkDevToolsType(_entry('/app.js')), 'JS');
    expect(proxyNetworkDevToolsType(_entry('/logo.png')), 'Img');
    expect(proxyNetworkDevToolsType(_entry('/font.woff2')), 'Font');
    expect(proxyNetworkDevToolsType(_entry('/module.wasm')), 'Wasm');
    expect(
      proxyNetworkDevToolsType(_entry('/api/users', method: 'POST')),
      'Fetch/XHR',
    );
    expect(proxyNetworkDevToolsType(_entry('/index.html')), 'Doc');
  });

  test('filters out internal proxy log lines from network table', () {
    final state = EmbeddedProxyRequestLogState(
      entries: [
        _entry('SESSION 127.0.0.1:123 connected', type: 'log', method: 'LOG'),
        _entry('/api/users', method: 'POST'),
      ],
      typeFilter: 'All',
    );

    expect(state.filteredEntries, hasLength(1));
    expect(state.filteredEntries.single.path, '/api/users');
  });
}

ProxyNetworkEntry _entry(
  String path, {
  String method = 'GET',
  String type = 'document',
}) {
  return ProxyNetworkEntry(
    id: path,
    startedAtMs: 0,
    method: method,
    url: path.startsWith('http') ? path : 'https://example.com$path',
    host: 'example.com',
    path: path,
    protocol: 'HTTPS/1.1',
    type: type,
    status: 200,
    statusText: 'OK',
    durationMs: 1,
    requestHeaders: const [],
    responseHeaders: const [],
    requestBodyPreview: '',
    responseBodyPreview: '',
    bytesSent: 0,
    bytesReceived: 0,
    remoteAddress: '',
    upstreamAddress: '',
    error: '',
    phase: 'complete',
  );
}
