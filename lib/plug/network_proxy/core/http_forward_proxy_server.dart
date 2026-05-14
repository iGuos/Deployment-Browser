import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mitm_certificate_manager.dart';
import 'proxy_network_event.dart';

/// 日志回调（可选）；由上层注入，避免 plug 依赖 logger。
typedef HttpForwardProxyLog = void Function(String line);
typedef HttpForwardProxyNetworkEvent = void Function(ProxyNetworkEvent event);

/// 极简 HTTP 转发代理：支持 **CONNECT**（HTTPS 隧道）与 **http://** 绝对 URI 的 GET/POST 等。
///
/// 监听侧默认使用 TLS 包裹代理协议，避免公网穿透入口看到明文 CONNECT 后拦截。
/// 无认证、无缓存；适用于本机或小范围调试。仅使用 `dart:io`。
class HttpForwardProxyServer {
  HttpForwardProxyServer({
    this.onLog,
    this.onNetworkEvent,
    bool encrypted = true,
    SecurityContext? securityContext,
    MitmCertificateManager? mitmCertificateManager,
  }) : _defaultEncrypted = encrypted,
       _securityContext =
           securityContext ?? _defaultEncryptedProxySecurityContext(),
       _mitmCertificates = mitmCertificateManager ?? MitmCertificateManager();

  final HttpForwardProxyLog? onLog;
  final HttpForwardProxyNetworkEvent? onNetworkEvent;
  final bool _defaultEncrypted;
  final SecurityContext _securityContext;
  final MitmCertificateManager _mitmCertificates;
  String _authUsername = '';
  String _authPassword = '';
  bool _mitmEnabled = false;
  bool _mitmRemoteClientsEnabled = false;
  List<String> _proxyAllowHosts = const [];
  final Map<String, DateTime> _clientsNeedingMitmCertificate = {};
  final Map<String, DateTime> _clientsDownloadedMitmCertificate = {};

  static const String mitmTrustProbeHost = 'deployment.mitm-probe.invalid';

  Stream<Socket>? _server;
  Future<void> Function()? _closeServer;

  bool get isListening => _server != null;

  void _log(String m) => onLog?.call(m);
  void _emit(ProxyNetworkEvent e) => onNetworkEvent?.call(e);

  /// 若已在监听，会先关闭再绑定。
  Future<void> bind({
    required InternetAddress address,
    required int port,
    bool? encrypted,
    bool mitmEnabled = false,
    bool mitmRemoteClientsEnabled = false,
    List<String> proxyAllowHosts = const [],
    String authUsername = '',
    String authPassword = '',
  }) async {
    await close();
    try {
      final useEncrypted = encrypted ?? _defaultEncrypted;
      _authUsername = authUsername.trim();
      _authPassword = authPassword;
      _mitmEnabled = mitmEnabled;
      _mitmRemoteClientsEnabled = mitmRemoteClientsEnabled;
      _proxyAllowHosts = proxyAllowHosts;
      _clientsNeedingMitmCertificate.clear();
      _clientsDownloadedMitmCertificate.clear();
      final Stream<Socket> server;
      final Future<void> Function() closer;
      if (useEncrypted) {
        final secureServer = await SecureServerSocket.bind(
          address,
          port,
          _securityContext,
          supportedProtocols: const ['http/1.1'],
        );
        server = secureServer;
        closer = () async {
          await secureServer.close();
        };
      } else {
        final plainServer = await ServerSocket.bind(address, port);
        server = plainServer;
        closer = () async {
          await plainServer.close();
        };
      }
      _server = server;
      _closeServer = closer;
      server.listen(
        (Socket s) {
          unawaited(_handleClient(s));
        },
        onError: (Object e) => _log('accept: $e'),
        cancelOnError: false,
      );
      _log('listening ${useEncrypted ? 'tls ' : ''}${address.address}:$port');
    } catch (e) {
      _log('bind failed: $e');
      rethrow;
    }
  }

  Future<void> close() async {
    final closer = _closeServer;
    _server = null;
    _closeServer = null;
    if (closer != null) {
      try {
        await closer();
      } catch (_) {}
      _log('closed listener');
    }
  }

  Future<void> _handleClient(Socket client) async {
    final buffer = <int>[];
    late final StreamSubscription<List<int>> sub;
    final headerPhase = Completer<void>();
    final ctx = _ProxyClientCtx();
    final peer = '${client.remoteAddress.address}:${client.remotePort}';
    _log('SESSION $peer connected');
    try {
      sub = client.listen(
        (chunk) {
          if (ctx.inTunnel) {
            final up = ctx.upstream;
            if (up == null) return;
            if (chunk.isEmpty) return;
            up.add(chunk);
            unawaited(up.flush().catchError((_) {}));
            return;
          }
          buffer.addAll(chunk);
          final bodyStart = _findHeaderBodyStart(buffer);
          if (bodyStart >= 0) {
            ctx.dispatchScheduled = true;
            sub.pause();
            final headerBytes = buffer.sublist(0, bodyStart - 4);
            final rest = Uint8List.fromList(buffer.sublist(bodyStart));
            buffer.clear();
            final headerText = utf8.decode(headerBytes, allowMalformed: true);
            unawaited(() async {
              try {
                await _dispatchWithSingleClientSubscription(
                  ctx,
                  client,
                  sub,
                  headerText,
                  rest,
                );
              } catch (e) {
                _log('dispatch: $e');
              } finally {
                try {
                  sub.resume();
                } catch (_) {}
                if (!headerPhase.isCompleted) headerPhase.complete();
              }
            }());
            return;
          }
          if (buffer.length > 262144) {
            ctx.dispatchScheduled = true;
            sub.pause();
            unawaited(() async {
              try {
                await _writeHttpError(
                  client,
                  413,
                  reason: 'Request Entity Too Large',
                );
              } finally {
                try {
                  sub.resume();
                } catch (_) {}
                if (!headerPhase.isCompleted) headerPhase.complete();
              }
            }());
          }
        },
        onError: (Object e, StackTrace st) {
          if (ctx.inTunnel && ctx.forwardLabel != null) {
            ctx.clientError = e.toString();
          }
          if (ctx.inTunnel) {
            ctx.clientTunnelReadDone = true;
            ctx.checkTunnelDone();
          } else if (!headerPhase.isCompleted) {
            headerPhase.completeError(e, st);
          }
        },
        onDone: () {
          if (ctx.inTunnel) {
            ctx.clientTunnelReadDone = true;
            ctx.checkTunnelDone();
          } else if (!ctx.dispatchScheduled && !headerPhase.isCompleted) {
            headerPhase.complete();
          }
        },
        cancelOnError: false,
      );
      await headerPhase.future;
    } catch (e) {
      _log('SESSION $peer error: $e');
    } finally {
      try {
        await ctx.upstreamSub?.cancel();
      } catch (_) {}
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await ctx.upstream?.close();
      } catch (_) {}
      try {
        await client.close();
      } catch (_) {}
      _log('SESSION $peer closed');
    }
  }

  /// [Socket] 单订阅：不能在 [cancel] 后再 [listen]；隧道阶段沿用 [clientSub] 收字节。
  Future<void> _dispatchWithSingleClientSubscription(
    _ProxyClientCtx ctx,
    Socket client,
    StreamSubscription<List<int>> clientSub,
    String headerText,
    Uint8List rest,
  ) async {
    final lines = headerText.split('\r\n');
    if (lines.isEmpty || lines.first.isEmpty) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    final first = lines.first;
    if (_isProxyStatusFirstLine(first)) {
      await _writeProxyStatusResponse(client);
      return;
    }
    if (_isMitmCertificatePortalFirstLine(first)) {
      await _handleHttpAbsoluteUriTunnel(ctx, client, clientSub, lines, rest);
      return;
    }
    final isMitmTrustProbe = _isMitmTrustProbeConnectFirstLine(first);
    if (_shouldShowMitmCertificatePromptOnClient(client.remoteAddress) &&
        !isMitmTrustProbe) {
      if (first.startsWith('CONNECT ')) {
        await _writeMitmCertificateRequiredForConnect(client);
      } else {
        await _writeMitmCertificatePortalResponse(
          client,
          Uri(path: '/__proxy/cert'),
        );
      }
      return;
    }
    if (isMitmTrustProbe) {
      await _handleConnectTunnel(ctx, client, clientSub, first, rest);
      return;
    }
    if (!_isProxyAuthorized(lines)) {
      _log('${lines.first} | 407 Proxy Authentication Required');
      _emit(
        ProxyNetworkEvent(
          kind: ProxyNetworkEventKind.failed,
          entry: _entryFromRequestLines(
            id: _newNetworkId(),
            lines: lines,
            remoteAddress:
                '${client.remoteAddress.address}:${client.remotePort}',
            status: 407,
            statusText: 'Proxy Authentication Required',
            phase: 'failed',
            error: 'Proxy authentication required',
          ),
        ),
      );
      await _writeProxyAuthRequired(client);
      return;
    }
    if (first.startsWith('CONNECT ')) {
      await _handleConnectTunnel(ctx, client, clientSub, first, rest);
      return;
    }
    await _handleHttpAbsoluteUriTunnel(ctx, client, clientSub, lines, rest);
  }

  Future<void> _writeMitmCertificateRequiredForConnect(Socket client) async {
    await _writePlainHttpResponse(
      client,
      428,
      'Certificate Required',
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'X-Deployment-Proxy-Certificate-Required': '1',
        'X-Deployment-Proxy-Certificate-Path': '/__proxy/cert',
      },
      body: utf8.encode(_mitmCertificatePortalHtml()),
    );
  }

  Future<void> _writeProxyStatusResponse(Socket client) async {
    String? fingerprint;
    if (_mitmEnabled) {
      try {
        fingerprint = await _mitmCertificates
            .rootCertificateSha256Fingerprint();
      } catch (_) {}
    }
    await _writePlainHttpResponse(
      client,
      200,
      'OK',
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: utf8.encode(
        jsonEncode({
          'ok': true,
          'mitmEnabled': _mitmEnabled,
          'mitmRemoteClientsEnabled': _mitmRemoteClientsEnabled,
          'mitmAppliesToClient':
              _mitmEnabled &&
              (_mitmRemoteClientsEnabled ||
                  _isLoopbackAddress(client.remoteAddress)),
          'clientAddress': client.remoteAddress.address,
          'certificateInstallPath': '/__proxy/cert',
          'mitmTrustProbeHost': mitmTrustProbeHost,
          if (fingerprint != null) ...{'rootCertificateSha256': fingerprint},
        }),
      ),
    );
  }

  /// 返回 `\r\n\r\n` 之后第一个字节的下标；未找到返回 `-1`。
  static int _findHeaderBodyStart(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 0x0d &&
          b[i + 1] == 0x0a &&
          b[i + 2] == 0x0d &&
          b[i + 3] == 0x0a) {
        return i + 4;
      }
    }
    return -1;
  }

  static String _newNetworkId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_networkSerial++}';

  static int _networkSerial = 0;

  static ProxyNetworkEntry _entryFromRequestLines({
    required String id,
    required List<String> lines,
    required String remoteAddress,
    int? status,
    String statusText = '',
    int? durationMs,
    String upstreamAddress = '',
    String error = '',
    String phase = 'pending',
    int bytesSent = 0,
    int bytesReceived = 0,
    List<ProxyHeader> responseHeaders = const [],
    String requestBodyPreview = '',
    String responseBodyPreview = '',
  }) {
    final first = lines.isEmpty ? '' : lines.first;
    final parts = first.split(RegExp(r'\s+'));
    final method = parts.isNotEmpty ? parts[0] : '';
    final target = parts.length > 1 ? parts[1] : '';
    final headers = _parseHeaderLines(lines.skip(1));
    final hostHeader = headers
        .where((h) => h.name.toLowerCase() == 'host')
        .map((h) => h.value)
        .firstOrNull;
    final isConnect = method.toUpperCase() == 'CONNECT';
    Uri? uri;
    if (!isConnect) {
      uri = Uri.tryParse(target);
    }
    final host = isConnect
        ? target.split(':').first
        : (uri?.host.isNotEmpty == true ? uri!.host : hostHeader ?? '');
    final path = isConnect
        ? target
        : (uri?.path.isNotEmpty == true ? uri!.path : target);
    final url = isConnect ? 'https://$target' : target;
    return ProxyNetworkEntry(
      id: id,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      method: method,
      url: url,
      host: host,
      path: path,
      protocol: isConnect ? 'CONNECT' : 'HTTP/1.1',
      type: isConnect ? 'tunnel' : 'document',
      status: status,
      statusText: statusText,
      durationMs: durationMs,
      requestHeaders: headers,
      responseHeaders: responseHeaders,
      requestBodyPreview: requestBodyPreview,
      responseBodyPreview: responseBodyPreview,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      remoteAddress: remoteAddress,
      upstreamAddress: upstreamAddress,
      error: error,
      phase: phase,
    );
  }

  static List<ProxyHeader> _parseHeaderLines(Iterable<String> lines) {
    final headers = <ProxyHeader>[];
    for (final line in lines) {
      final sep = line.indexOf(':');
      if (sep <= 0) continue;
      headers.add(
        ProxyHeader(
          name: line.substring(0, sep).trim(),
          value: line.substring(sep + 1).trim(),
        ),
      );
    }
    return headers;
  }

  static (
    int? status,
    String statusText,
    List<ProxyHeader> headers,
    int bodyStart,
  )?
  _parseResponseHeader(List<int> bytes) {
    final bodyStart = _findHeaderBodyStart(bytes);
    if (bodyStart < 0) return null;
    final headerText = utf8.decode(
      bytes.sublist(0, bodyStart - 4),
      allowMalformed: true,
    );
    final lines = headerText.split('\r\n');
    final statusLine = lines.isEmpty ? '' : lines.first;
    final parts = statusLine.split(RegExp(r'\s+'));
    final status = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final statusText = parts.length > 2 ? parts.skip(2).join(' ') : '';
    return (status, statusText, _parseHeaderLines(lines.skip(1)), bodyStart);
  }

  static String _previewBytes(List<int> bytes, {int max = 8192}) {
    if (bytes.isEmpty) return '';
    final clipped = bytes.length > max ? bytes.sublist(0, max) : bytes;
    return utf8.decode(clipped, allowMalformed: true);
  }

  static String _previewHttpBody(
    List<int> bytes,
    List<ProxyHeader> headers, {
    int max = 8192,
  }) {
    if (bytes.isEmpty) return '';
    var body = List<int>.from(bytes);
    final transferEncoding = _headerValue(headers, 'transfer-encoding');
    if (transferEncoding?.toLowerCase().contains('chunked') == true) {
      body = _decodeChunkedPreview(body);
    }
    final encoding = _headerValue(headers, 'content-encoding')?.toLowerCase();
    if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
      try {
        if (encoding.contains('gzip') || encoding.contains('x-gzip')) {
          body = gzip.decode(body);
        } else if (encoding.contains('deflate')) {
          body = zlib.decode(body);
        } else {
          return '[${encoding.toUpperCase()} compressed body preview unsupported]';
        }
      } catch (_) {
        return '[${encoding.toUpperCase()} compressed body preview unavailable: captured ${bytes.length} bytes]';
      }
    }
    return _previewBytes(body, max: max);
  }

  static List<int> _decodeChunkedPreview(List<int> bytes) {
    final out = <int>[];
    var offset = 0;
    while (offset < bytes.length) {
      final lineEnd = _indexOfCrlf(bytes, offset);
      if (lineEnd < 0) break;
      final line = utf8.decode(
        bytes.sublist(offset, lineEnd),
        allowMalformed: true,
      );
      final sizeText = line.split(';').first.trim();
      final size = int.tryParse(sizeText, radix: 16);
      if (size == null || size == 0) break;
      final dataStart = lineEnd + 2;
      final dataEnd = dataStart + size;
      if (dataEnd > bytes.length) break;
      out.addAll(bytes.sublist(dataStart, dataEnd));
      offset = dataEnd + 2;
    }
    return out.isEmpty ? bytes : out;
  }

  static int _indexOfCrlf(List<int> bytes, int start) {
    for (var i = start; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x0d && bytes[i + 1] == 0x0a) return i;
    }
    return -1;
  }

  static String? _headerValue(List<ProxyHeader> headers, String name) {
    final lower = name.toLowerCase();
    for (final header in headers) {
      if (header.name.toLowerCase() == lower) return header.value;
    }
    return null;
  }

  Future<void> _handleConnectTunnel(
    _ProxyClientCtx ctx,
    Socket client,
    StreamSubscription<List<int>> clientSub,
    String firstLine,
    Uint8List rest,
  ) async {
    final uriPart = firstLine.substring('CONNECT '.length).trim();
    final sp = uriPart.indexOf(' ');
    final authority = sp < 0 ? uriPart : uriPart.substring(0, sp);
    final hp = _parseAuthority(authority, defaultPort: 443);
    if (hp == null) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    final (host, port) = hp;
    final started = Stopwatch()..start();
    final networkId = _newNetworkId();
    final remoteAddress =
        '${client.remoteAddress.address}:${client.remotePort}';
    final startedEntry = _entryFromRequestLines(
      id: networkId,
      lines: [firstLine],
      remoteAddress: remoteAddress,
      phase: 'pending',
    );
    if (!_isProxyTargetAllowed(host)) {
      _log('CONNECT $authority | 403 Forbidden | allowlist_blocked');
      _emit(
        ProxyNetworkEvent(
          kind: ProxyNetworkEventKind.failed,
          entry: startedEntry.copyWith(
            status: 403,
            statusText: 'Forbidden',
            error: 'Blocked by proxy allowlist',
            phase: 'blocked',
          ),
        ),
      );
      await _writeHttpError(client, 403, reason: 'Forbidden');
      return;
    }
    final shouldMitm =
        _mitmEnabled &&
        (_mitmRemoteClientsEnabled || _isLoopbackAddress(client.remoteAddress));
    if (shouldMitm) {
      await _handleConnectMitm(
        ctx: ctx,
        client: client,
        clientSub: clientSub,
        connectEntry: startedEntry,
        started: started,
        authority: authority,
        host: host,
        port: port,
        remoteAddress: remoteAddress,
        bufferedClientHello: rest,
      );
      return;
    }
    _emit(
      ProxyNetworkEvent(
        kind: ProxyNetworkEventKind.started,
        entry: startedEntry,
      ),
    );
    ctx.forwardLabel = 'CONNECT $authority';
    late final Socket upstream;
    try {
      upstream = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      _log(
        'CONNECT $authority | 502 Bad Gateway | dial_failed=$e | ${started.elapsedMilliseconds}ms',
      );
      ctx.forwardLabel = null;
      _emit(
        ProxyNetworkEvent(
          kind: ProxyNetworkEventKind.failed,
          entry: startedEntry.copyWith(
            status: 502,
            statusText: 'Bad Gateway',
            durationMs: started.elapsedMilliseconds,
            error: e.toString(),
            phase: 'failed',
          ),
        ),
      );
      await _writeHttpError(client, 502, reason: 'Bad Gateway');
      return;
    }
    final upstreamPeer =
        '${upstream.remoteAddress.address}:${upstream.remotePort}';
    ctx.upstream = upstream;
    ctx.upstreamReadDone = false;
    ctx.clientTunnelReadDone = false;
    ctx.tunnelDone = Completer<void>();
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    await client.flush();
    _log(
      'CONNECT $authority | 200 Connection Established | upstream=$upstreamPeer | opened',
    );
    _emit(
      ProxyNetworkEvent(
        kind: ProxyNetworkEventKind.updated,
        entry: startedEntry.copyWith(
          status: 200,
          statusText: _mitmEnabled
              ? 'Connection Established (HTTPS decrypt requested)'
              : 'Connection Established',
          upstreamAddress: upstreamPeer,
          phase: 'open',
        ),
      ),
    );
    if (rest.isNotEmpty) {
      upstream.add(rest);
      await upstream.flush();
    }
    ctx.upstreamSub = upstream.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        client.add(chunk);
        unawaited(client.flush().catchError((_) {}));
      },
      onDone: () {
        ctx.upstreamReadDone = true;
        ctx.checkTunnelDone();
      },
      onError: (Object e, StackTrace st) {
        ctx.upstreamError = e.toString();
        ctx.upstreamReadDone = true;
        ctx.checkTunnelDone();
      },
      cancelOnError: false,
    );
    ctx.inTunnel = true;
    clientSub.resume();
    await ctx.tunnelDone!.future;
    ctx.inTunnel = false;
    final errors = _formatTunnelErrors(ctx);
    _log(
      'CONNECT $authority | 200 Connection Established | upstream=$upstreamPeer | client_done=${ctx.clientTunnelReadDone} upstream_done=${ctx.upstreamReadDone}${rest.isNotEmpty ? ' | pipelined=${rest.length}B' : ''}$errors | ${started.elapsedMilliseconds}ms',
    );
    _emit(
      ProxyNetworkEvent(
        kind: ProxyNetworkEventKind.completed,
        entry: startedEntry.copyWith(
          status: 200,
          statusText: _mitmEnabled
              ? 'Connection Established (HTTPS decrypt requested)'
              : 'Connection Established',
          durationMs: started.elapsedMilliseconds,
          bytesSent: rest.length,
          upstreamAddress: upstreamPeer,
          error: errors.trim(),
          phase: 'complete',
        ),
      ),
    );
    try {
      await ctx.upstreamSub?.cancel();
    } catch (_) {}
    ctx.upstreamSub = null;
    try {
      await upstream.close();
    } catch (_) {}
    ctx.upstream = null;
    ctx.forwardLabel = null;
  }

  Future<void> _handleConnectMitm({
    required _ProxyClientCtx ctx,
    required Socket client,
    required StreamSubscription<List<int>> clientSub,
    required ProxyNetworkEntry connectEntry,
    required Stopwatch started,
    required String authority,
    required String host,
    required int port,
    required String remoteAddress,
    required Uint8List bufferedClientHello,
  }) async {
    ctx.forwardLabel = 'MITM $authority';
    _MitmClientTlsBridge? clientBridge;
    SecureSocket? clientTls;
    SecureSocket? upstreamTls;
    var connectAccepted = false;
    var clientTlsEstablished = false;
    try {
      final hostCert = await _mitmCertificates.ensureHostCertificate(host);
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await client.flush();
      connectAccepted = true;

      clientBridge = await _openMitmClientTlsBridge(ctx, client, clientSub);
      clientTls = await SecureSocket.secureServer(
        clientBridge.serverSide,
        _mitmCertificates.securityContextForHost(hostCert),
        bufferedData: bufferedClientHello,
        supportedProtocols: const ['http/1.1'],
      );
      clientTlsEstablished = true;
      if (_isMitmTrustProbeHost(host)) {
        _log('MITM $authority | client tls established | trust_probe');
        await _handleMitmTrustProbe(clientTls);
        return;
      }
      upstreamTls = await SecureSocket.connect(
        host,
        port,
        supportedProtocols: const ['http/1.1'],
        onBadCertificate: (certificate) {
          _log(
            'MITM $authority | upstream certificate not trusted: ${certificate.subject}',
          );
          return true;
        },
      );
      final upstreamPeer =
          '${upstreamTls.remoteAddress.address}:${upstreamTls.remotePort}';
      _log('MITM $authority | tls established | upstream=$upstreamPeer');
      await _forwardMitmHttp11(
        clientTls: clientTls,
        upstreamTls: upstreamTls,
        host: host,
        port: port,
        remoteAddress: remoteAddress,
        upstreamAddress: upstreamPeer,
      );
    } catch (e) {
      _log('MITM $authority | failed=$e');
      if (connectAccepted && !clientTlsEstablished) {
        _rememberClientNeedsMitmCertificate(client.remoteAddress);
        _emit(
          ProxyNetworkEvent(
            kind: ProxyNetworkEventKind.failed,
            entry: connectEntry.copyWith(
              statusText: 'HTTPS 解密证书未信任',
              durationMs: started.elapsedMilliseconds,
              bytesSent: bufferedClientHello.length,
              error: e.toString(),
              phase: proxyNetworkPhaseMitmClientCertificateRequired,
            ),
          ),
        );
      }
      if (!connectAccepted) {
        await _writeHttpError(client, 502, reason: 'MITM Failed');
      }
    } finally {
      try {
        await clientTls?.close();
      } catch (_) {}
      try {
        await upstreamTls?.close();
      } catch (_) {}
      try {
        await clientBridge?.close();
      } catch (_) {}
      ctx.inTunnel = false;
      ctx.upstream = null;
      ctx.forwardLabel = null;
    }
  }

  Future<_MitmClientTlsBridge> _openMitmClientTlsBridge(
    _ProxyClientCtx ctx,
    Socket client,
    StreamSubscription<List<int>> clientSub,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final outboundTask = Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final inboundTask = server.first;
      final outbound = await outboundTask;
      final inbound = await inboundTask;
      final bridge = _MitmClientTlsBridge(
        serverSide: inbound,
        clientSide: outbound,
        outerClient: client,
      );
      ctx.upstream = outbound;
      ctx.inTunnel = true;
      bridge.clientSideSub = outbound.listen(
        bridge.forwardToOuterClient,
        onDone: () {
          bridge.markClientSideDone();
          ctx.upstreamReadDone = true;
          ctx.checkTunnelDone();
        },
        onError: (Object e, StackTrace st) {
          bridge.markClientSideDone();
          ctx.upstreamError = e.toString();
          ctx.upstreamReadDone = true;
          ctx.checkTunnelDone();
        },
        cancelOnError: false,
      );
      clientSub.resume();
      return bridge;
    } finally {
      await server.close();
    }
  }

  Future<void> _forwardMitmHttp11({
    required SecureSocket clientTls,
    required SecureSocket upstreamTls,
    required String host,
    required int port,
    required String remoteAddress,
    required String upstreamAddress,
  }) async {
    final clientReader = _HttpMessageReader(clientTls);
    final upstreamReader = _HttpMessageReader(upstreamTls);
    try {
      while (true) {
        final reqHead = await clientReader.readHead();
        if (reqHead == null) break;
        final reqLine = reqHead.startLine.split(RegExp(r'\s+'));
        if (reqLine.length < 3) break;
        final method = reqLine[0];
        final target = reqLine[1];
        final url = _mitmUrl(host, port, target);
        final requestBody = <int>[];
        final started = Stopwatch()..start();
        final networkId = _newNetworkId();
        upstreamTls.add(reqHead.rawBytes);
        final sentBodyBytes = await _transferHttpBody(
          reader: clientReader,
          sink: upstreamTls,
          head: reqHead,
          previewSink: requestBody,
        );
        await upstreamTls.flush();

        final entry = ProxyNetworkEntry(
          id: networkId,
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
          method: method,
          url: url,
          host: host,
          path: _mitmPath(target),
          protocol: 'HTTPS/1.1',
          type: 'document',
          status: null,
          statusText: '',
          durationMs: null,
          requestHeaders: reqHead.headers,
          responseHeaders: const [],
          requestBodyPreview: _previewHttpBody(requestBody, reqHead.headers),
          responseBodyPreview: '',
          bytesSent: reqHead.rawBytes.length + sentBodyBytes,
          bytesReceived: 0,
          remoteAddress: remoteAddress,
          upstreamAddress: upstreamAddress,
          error: '',
          phase: 'pending',
        );
        _emit(
          ProxyNetworkEvent(kind: ProxyNetworkEventKind.started, entry: entry),
        );

        final resHead = await upstreamReader.readHead();
        if (resHead == null) {
          _emit(
            ProxyNetworkEvent(
              kind: ProxyNetworkEventKind.failed,
              entry: entry.copyWith(
                durationMs: started.elapsedMilliseconds,
                error: 'upstream closed before response',
                phase: 'failed',
              ),
            ),
          );
          break;
        }
        clientTls.add(resHead.rawBytes);
        final status = _statusCodeFromResponseLine(resHead.startLine);
        final statusText = _statusTextFromResponseLine(resHead.startLine);
        final responsePreview = <int>[];
        _emit(
          ProxyNetworkEvent(
            kind: ProxyNetworkEventKind.updated,
            entry: entry.copyWith(
              status: status,
              statusText: statusText,
              responseHeaders: resHead.headers,
              phase: 'receiving',
            ),
          ),
        );
        final receivedBodyBytes = await _transferHttpBody(
          reader: upstreamReader,
          sink: clientTls,
          head: resHead,
          previewSink: responsePreview,
          readUntilDone: _responseReadsUntilClose(resHead, method),
        );
        await clientTls.flush();
        _emit(
          ProxyNetworkEvent(
            kind: ProxyNetworkEventKind.completed,
            entry: entry.copyWith(
              status: status,
              statusText: statusText,
              durationMs: started.elapsedMilliseconds,
              responseHeaders: resHead.headers,
              responseBodyPreview: _previewHttpBody(
                responsePreview,
                resHead.headers,
              ),
              bytesReceived: resHead.rawBytes.length + receivedBodyBytes,
              phase: 'complete',
            ),
          ),
        );
        _log(
          'MITM $method $url | ${status ?? '-'} $statusText | ${started.elapsedMilliseconds}ms',
        );
        if (reqHead.connectionClose || resHead.connectionClose) break;
      }
    } finally {
      await clientReader.cancel();
      await upstreamReader.cancel();
    }
  }

  Future<void> _handleMitmTrustProbe(SecureSocket clientTls) async {
    final reader = _HttpMessageReader(clientTls);
    try {
      final head = await reader.readHead();
      if (head == null) {
        _log('MITM trust probe | empty request');
        return;
      }
      _log('MITM trust probe | ${head.startLine}');
      clientTls.add(
        utf8.encode(
          'HTTP/1.1 204 No Content\r\n'
          'Connection: close\r\n'
          'Content-Length: 0\r\n'
          '\r\n',
        ),
      );
      await clientTls.flush();
    } finally {
      await reader.cancel();
    }
  }

  static String _mitmUrl(String host, int port, String target) {
    if (target.startsWith('https://')) return target;
    final authority = port == 443 ? host : '$host:$port';
    final path = _mitmPath(target);
    return 'https://$authority$path';
  }

  static String _mitmPath(String target) {
    if (target.startsWith('http://') || target.startsWith('https://')) {
      final uri = Uri.tryParse(target);
      if (uri == null) return target;
      final path = uri.path.isEmpty ? '/' : uri.path;
      return uri.hasQuery ? '$path?${uri.query}' : path;
    }
    return target.isEmpty ? '/' : target;
  }

  static int? _statusCodeFromResponseLine(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    return int.tryParse(parts[1]);
  }

  static String _statusTextFromResponseLine(String line) {
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 3) return '';
    return parts.skip(2).join(' ');
  }

  static bool _responseReadsUntilClose(_HttpMessageHead head, String method) {
    if (method.toUpperCase() == 'HEAD') return false;
    final status = _statusCodeFromResponseLine(head.startLine);
    if (status != null &&
        ((status >= 100 && status < 200) || status == 204 || status == 304)) {
      return false;
    }
    return head.contentLength == null && !head.chunked && head.connectionClose;
  }

  static bool _isLoopbackAddress(InternetAddress address) {
    if (address.isLoopback) return true;
    final value = address.address;
    return value == '::1' || value == '0:0:0:0:0:0:0:1';
  }

  void _rememberClientNeedsMitmCertificate(InternetAddress address) {
    if (_isLoopbackAddress(address)) return;
    _clientsNeedingMitmCertificate[address.address] = DateTime.now();
    _clientsDownloadedMitmCertificate.remove(address.address);
  }

  void _rememberClientDownloadedMitmCertificate(InternetAddress address) {
    if (_isLoopbackAddress(address)) return;
    _clientsDownloadedMitmCertificate[address.address] = DateTime.now();
    _clientsNeedingMitmCertificate.remove(address.address);
  }

  bool _shouldShowMitmCertificatePromptOnClient(InternetAddress address) {
    if (!_mitmEnabled ||
        !_mitmRemoteClientsEnabled ||
        _isLoopbackAddress(address)) {
      return false;
    }
    final markedAt = _clientsNeedingMitmCertificate[address.address];
    if (markedAt != null) {
      if (DateTime.now().difference(markedAt) <= const Duration(minutes: 10)) {
        return true;
      }
      _clientsNeedingMitmCertificate.remove(address.address);
    }
    final downloadedAt = _clientsDownloadedMitmCertificate[address.address];
    if (downloadedAt == null) return true;
    if (DateTime.now().difference(downloadedAt) <=
        const Duration(minutes: 10)) {
      return false;
    }
    _clientsDownloadedMitmCertificate.remove(address.address);
    return true;
  }

  static Future<int> _transferHttpBody({
    required _HttpMessageReader reader,
    required Socket sink,
    required _HttpMessageHead head,
    required List<int> previewSink,
    bool readUntilDone = false,
  }) async {
    var count = 0;
    void capture(List<int> bytes) {
      final remaining = 8192 - previewSink.length;
      if (remaining <= 0) return;
      previewSink.addAll(bytes.take(remaining));
    }

    if (head.chunked) {
      while (true) {
        final line = await reader.readLine(includeDelimiter: true);
        if (line == null) break;
        sink.add(line);
        count += line.length;
        final text = utf8.decode(line, allowMalformed: true).trim();
        final sizeText = text.split(';').first.trim();
        final size = int.tryParse(sizeText, radix: 16);
        if (size == null) break;
        if (size == 0) {
          while (true) {
            final trailer = await reader.readLine(includeDelimiter: true);
            if (trailer == null) break;
            sink.add(trailer);
            count += trailer.length;
            if (trailer.length == 2 &&
                trailer[0] == 0x0d &&
                trailer[1] == 0x0a) {
              return count;
            }
          }
          return count;
        }
        final chunk = await reader.readExactly(size + 2);
        if (chunk == null) break;
        sink.add(chunk);
        capture(chunk.take(size).toList(growable: false));
        count += chunk.length;
      }
      return count;
    }

    final length = head.contentLength;
    if (length != null && length > 0) {
      var remaining = length;
      while (remaining > 0) {
        final part = await reader.readUpTo(
          remaining > 16384 ? 16384 : remaining,
        );
        if (part == null || part.isEmpty) break;
        sink.add(part);
        capture(part);
        count += part.length;
        remaining -= part.length;
      }
      return count;
    }

    if (readUntilDone) {
      while (true) {
        final part = await reader.readUpTo(16384);
        if (part == null || part.isEmpty) break;
        sink.add(part);
        capture(part);
        count += part.length;
      }
    }
    return count;
  }

  /// [authority] 如 `host:443` 或 `[::1]:443`。
  static (String host, int port)? _parseAuthority(
    String authority, {
    required int defaultPort,
  }) {
    final a = authority.trim();
    if (a.isEmpty) return null;
    if (a.startsWith('[')) {
      final close = a.indexOf(']');
      if (close < 0) return null;
      final host = a.substring(1, close);
      if (close + 1 < a.length && a[close + 1] == ':') {
        final p = int.tryParse(a.substring(close + 2));
        if (p == null || p < 1 || p > 65535) return null;
        return (host, p);
      }
      return (host, defaultPort);
    }
    final colon = a.lastIndexOf(':');
    if (colon > 0 && colon < a.length - 1) {
      final host = a.substring(0, colon);
      final p = int.tryParse(a.substring(colon + 1));
      if (p == null || p < 1 || p > 65535) return null;
      return (host, p);
    }
    return (a, defaultPort);
  }

  Future<void> _handleHttpAbsoluteUriTunnel(
    _ProxyClientCtx ctx,
    Socket client,
    StreamSubscription<List<int>> clientSub,
    List<String> lines,
    Uint8List rest,
  ) async {
    final first = lines.first;
    final sp = first.indexOf(' ');
    if (sp < 0) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    final method = first.substring(0, sp).trim();
    var restLine = first.substring(sp + 1).trimLeft();
    final verIdx = restLine.toUpperCase().indexOf(' HTTP/');
    if (verIdx < 0) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    final urlPart = restLine.substring(0, verIdx).trim();
    final httpVer = restLine.substring(verIdx + 1).trim();
    if (_isMitmCertificatePortalPath(urlPart)) {
      await _writeMitmCertificatePortalResponse(client, Uri.parse(urlPart));
      return;
    }
    if (!urlPart.toLowerCase().startsWith('http://')) {
      await _writeHttpError(client, 501, reason: 'Not Implemented');
      return;
    }
    Uri uri;
    try {
      uri = Uri.parse(urlPart);
    } catch (_) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    if (uri.host.isEmpty) {
      await _writeHttpError(client, 400, reason: 'Bad Request');
      return;
    }
    if (_isMitmCertificatePortalRequest(uri)) {
      await _writeMitmCertificatePortalResponse(client, uri);
      return;
    }
    if (_shouldShowMitmCertificatePromptOnClient(client.remoteAddress)) {
      await _writeMitmCertificatePortalResponse(
        client,
        Uri(path: '/__proxy/cert'),
      );
      return;
    }
    final remoteAddress =
        '${client.remoteAddress.address}:${client.remotePort}';
    if (!_isProxyTargetAllowed(uri.host)) {
      final networkId = _newNetworkId();
      final blockedEntry = _entryFromRequestLines(
        id: networkId,
        lines: lines,
        remoteAddress: remoteAddress,
        status: 403,
        statusText: 'Forbidden',
        error: 'Blocked by proxy allowlist',
        phase: 'blocked',
      );
      _log('$method $urlPart | 403 Forbidden | allowlist_blocked');
      _emit(
        ProxyNetworkEvent(
          kind: ProxyNetworkEventKind.failed,
          entry: blockedEntry,
        ),
      );
      await _writeHttpError(client, 403, reason: 'Forbidden');
      return;
    }
    final port = uri.hasPort ? uri.port : 80;
    final pathQuery = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final path = pathQuery.isEmpty ? '/' : pathQuery;
    final newFirst = '$method $path $httpVer';
    final tail = lines.skip(1).toList();
    final hasHost = tail.any((l) => l.toLowerCase().startsWith('host:'));
    if (!hasHost) {
      final hostLine = uri.hasPort && uri.port != 80
          ? 'Host: ${uri.host}:${uri.port}'
          : 'Host: ${uri.host}';
      tail.insert(0, hostLine);
    }
    final headerBlock = [newFirst, ...tail].join('\r\n');
    final payload = utf8.encode('$headerBlock\r\n\r\n');
    final started = Stopwatch()..start();
    final networkId = _newNetworkId();
    final startedEntry = _entryFromRequestLines(
      id: networkId,
      lines: lines,
      remoteAddress: remoteAddress,
      bytesSent: payload.length + rest.length,
      requestBodyPreview: _previewHttpBody(
        rest,
        _parseHeaderLines(lines.skip(1)),
      ),
      phase: 'pending',
    );
    _emit(
      ProxyNetworkEvent(
        kind: ProxyNetworkEventKind.started,
        entry: startedEntry,
      ),
    );

    ctx.forwardLabel = '$method ${uri.host}:$port';
    Socket? upstream;
    try {
      upstream = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(seconds: 30),
      );
    } catch (e) {
      _log(
        '$method $urlPart | 502 Bad Gateway | dial_failed=$e | ${started.elapsedMilliseconds}ms',
      );
      ctx.forwardLabel = null;
      _emit(
        ProxyNetworkEvent(
          kind: ProxyNetworkEventKind.failed,
          entry: startedEntry.copyWith(
            status: 502,
            statusText: 'Bad Gateway',
            durationMs: started.elapsedMilliseconds,
            error: e.toString(),
            phase: 'failed',
          ),
        ),
      );
      await _writeHttpError(client, 502, reason: 'Bad Gateway');
      return;
    }
    final upstreamPeer =
        '${upstream.remoteAddress.address}:${upstream.remotePort}';
    ctx.upstream = upstream;
    ctx.upstreamReadDone = false;
    ctx.clientTunnelReadDone = false;
    ctx.tunnelDone = Completer<void>();
    var bytesReceived = 0;
    final responseHeaderBuffer = <int>[];
    var responseHeaderParsed = false;
    List<ProxyHeader> responseHeaders = const [];
    int? responseStatus;
    var responseStatusText = '';
    final responsePreview = <int>[];
    upstream.add(payload);
    if (rest.isNotEmpty) upstream.add(rest);
    await upstream.flush();
    ctx.upstreamSub = upstream.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        bytesReceived += chunk.length;
        if (!responseHeaderParsed) {
          responseHeaderBuffer.addAll(chunk);
          final parsed = _parseResponseHeader(responseHeaderBuffer);
          if (parsed != null) {
            responseHeaderParsed = true;
            responseStatus = parsed.$1;
            responseStatusText = parsed.$2;
            responseHeaders = parsed.$3;
            final body = responseHeaderBuffer.sublist(parsed.$4);
            responsePreview.addAll(body.take(8192 - responsePreview.length));
            _emit(
              ProxyNetworkEvent(
                kind: ProxyNetworkEventKind.updated,
                entry: startedEntry.copyWith(
                  status: responseStatus,
                  statusText: responseStatusText,
                  responseHeaders: responseHeaders,
                  bytesSent: payload.length + rest.length,
                  bytesReceived: bytesReceived,
                  upstreamAddress: upstreamPeer,
                  phase: 'receiving',
                ),
              ),
            );
          }
        } else if (responsePreview.length < 8192) {
          responsePreview.addAll(chunk.take(8192 - responsePreview.length));
        }
        client.add(chunk);
        unawaited(client.flush().catchError((_) {}));
      },
      onDone: () {
        ctx.upstreamReadDone = true;
        ctx.checkTunnelDone();
      },
      onError: (Object e, StackTrace st) {
        ctx.upstreamError = e.toString();
        ctx.upstreamReadDone = true;
        ctx.checkTunnelDone();
      },
      cancelOnError: false,
    );
    ctx.inTunnel = true;
    clientSub.resume();
    await ctx.tunnelDone!.future;
    ctx.inTunnel = false;
    final errors = _formatTunnelErrors(ctx);
    _log(
      '$method $urlPart | forwarded | upstream=$upstreamPeer | header=${payload.length}B${rest.isNotEmpty ? ' body=${rest.length}B' : ''} | client_done=${ctx.clientTunnelReadDone} upstream_done=${ctx.upstreamReadDone}$errors | ${started.elapsedMilliseconds}ms',
    );
    _emit(
      ProxyNetworkEvent(
        kind: errors.isEmpty
            ? ProxyNetworkEventKind.completed
            : ProxyNetworkEventKind.failed,
        entry: startedEntry.copyWith(
          status: responseStatus,
          statusText: responseStatusText,
          durationMs: started.elapsedMilliseconds,
          responseHeaders: responseHeaders,
          responseBodyPreview: _previewHttpBody(
            responsePreview,
            responseHeaders,
          ),
          bytesSent: payload.length + rest.length,
          bytesReceived: bytesReceived,
          upstreamAddress: upstreamPeer,
          error: errors.trim(),
          phase: errors.isEmpty ? 'complete' : 'failed',
        ),
      ),
    );
    try {
      await ctx.upstreamSub?.cancel();
    } catch (_) {}
    ctx.upstreamSub = null;
    try {
      await upstream.close();
    } catch (_) {}
    ctx.upstream = null;
    ctx.forwardLabel = null;
  }

  static Future<void> _writeHttpError(
    Socket client,
    int code, {
    required String reason,
  }) async {
    try {
      client.write(
        'HTTP/1.1 $code $reason\r\nConnection: close\r\nContent-Length: 0\r\n\r\n',
      );
      await client.flush();
    } catch (_) {}
  }

  static bool _isMitmCertificatePortalRequest(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'deployment.proxy' ||
        host == 'proxy.cert' ||
        host == 'mitm.proxy' ||
        _isMitmCertificatePortalPath(uri.path);
  }

  static bool _isProxyStatusFirstLine(String first) {
    final target = _requestTargetFromFirstLine(first);
    if (target == null) return false;
    final uri = Uri.tryParse(target);
    final path = uri?.path ?? target.split('?').first;
    return path == '/__proxy/status';
  }

  static bool _isMitmCertificatePortalFirstLine(String first) {
    final target = _requestTargetFromFirstLine(first);
    if (target == null) return false;
    if (_isMitmCertificatePortalPath(target)) return true;
    final uri = Uri.tryParse(target);
    return uri != null && _isMitmCertificatePortalRequest(uri);
  }

  static bool _isMitmTrustProbeConnectFirstLine(String first) {
    if (!first.startsWith('CONNECT ')) return false;
    final target = _requestTargetFromFirstLine(first);
    if (target == null) return false;
    final hp = _parseAuthority(target, defaultPort: 443);
    return hp != null && _isMitmTrustProbeHost(hp.$1);
  }

  static String? _requestTargetFromFirstLine(String first) {
    final sp = first.indexOf(' ');
    if (sp < 0) return null;
    final restLine = first.substring(sp + 1).trimLeft();
    final verIdx = restLine.toUpperCase().indexOf(' HTTP/');
    if (verIdx < 0) return null;
    return restLine.substring(0, verIdx).trim();
  }

  static bool _isMitmTrustProbeHost(String host) =>
      host.toLowerCase() == mitmTrustProbeHost;

  static bool _isMitmCertificatePortalPath(String rawPath) {
    final path = rawPath.split('?').first.toLowerCase();
    return path == '/__proxy/cert' ||
        path == '/__proxy/' ||
        path == '/__proxy/ca.cer' ||
        path == '/__proxy/ca.crt' ||
        path == '/__proxy/ca.pem';
  }

  Future<void> _writeMitmCertificatePortalResponse(
    Socket client,
    Uri uri,
  ) async {
    final path = uri.path.toLowerCase();
    final downloadPath =
        path == '/ca.cer' ||
        path == '/ca.crt' ||
        path == '/ca.pem' ||
        path == '/__proxy/ca.cer' ||
        path == '/__proxy/ca.crt' ||
        path == '/__proxy/ca.pem';
    final shouldOfferCertificate =
        _mitmEnabled &&
        (_mitmRemoteClientsEnabled || _isLoopbackAddress(client.remoteAddress));
    if (!shouldOfferCertificate) {
      await _writePlainHttpResponse(
        client,
        downloadPath ? 409 : 200,
        downloadPath ? 'HTTPS Decrypt Disabled' : 'OK',
        headers: {'Content-Type': 'text/html; charset=utf-8'},
        body: utf8.encode(
          _mitmCertificatePortalDisabledHtml(
            remoteClient: !_isLoopbackAddress(client.remoteAddress),
            mitmEnabled: _mitmEnabled,
          ),
        ),
      );
      return;
    }
    if (downloadPath) {
      try {
        final bytes = path == '/ca.pem'
            ? utf8.encode(await _mitmCertificates.rootCertificatePem())
            : await _mitmCertificates.rootCertificateDerBytes();
        await _writePlainHttpResponse(
          client,
          200,
          'OK',
          headers: {
            'Content-Type': path == '/ca.pem'
                ? 'application/x-pem-file'
                : 'application/x-x509-ca-cert',
            'Content-Disposition':
                'attachment; filename="deployment-mitm-root-ca${path.endsWith('.pem') ? '.pem' : '.cer'}"',
          },
          body: bytes,
        );
        _rememberClientDownloadedMitmCertificate(client.remoteAddress);
      } catch (e) {
        await _writePlainHttpResponse(
          client,
          500,
          'Certificate Error',
          body: utf8.encode('生成根证书失败：$e'),
        );
      }
      return;
    }

    var fingerprint = '';
    try {
      fingerprint = await _mitmCertificates.rootCertificateSha256Fingerprint();
    } catch (_) {}
    await _writePlainHttpResponse(
      client,
      200,
      'OK',
      headers: {'Content-Type': 'text/html; charset=utf-8'},
      body: utf8.encode(_mitmCertificatePortalHtml(fingerprint: fingerprint)),
    );
  }

  Future<void> _writePlainHttpResponse(
    Socket client,
    int code,
    String reason, {
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) async {
    try {
      final out = StringBuffer()
        ..write('HTTP/1.1 $code $reason\r\n')
        ..write('Connection: close\r\n')
        ..write('Cache-Control: no-store\r\n')
        ..write('Content-Length: ${body.length}\r\n');
      for (final entry in headers.entries) {
        out.write('${entry.key}: ${entry.value}\r\n');
      }
      out.write('\r\n');
      client.add(utf8.encode(out.toString()));
      if (body.isNotEmpty) client.add(body);
      await client.flush();
    } catch (_) {}
  }

  static String _mitmCertificatePortalHtml({String fingerprint = ''}) {
    final fingerprintHtml = fingerprint.isEmpty
        ? ''
        : '<p>当前根证书 SHA-256 指纹：<br><code>$fingerprint</code></p>';
    return '''
<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Deployment 代理证书安装</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f1117; color: #f1f5f9; }
    main { max-width: 720px; margin: 0 auto; padding: 28px 20px; }
    .card { background: #171b23; border: 1px solid #303746; border-radius: 16px; padding: 20px; }
    h1 { font-size: 22px; margin: 0 0 12px; }
    p, li { color: #cbd5e1; line-height: 1.55; }
    a.button { display: block; text-align: center; margin: 12px 0; padding: 13px 16px; border-radius: 12px; text-decoration: none; font-weight: 700; }
    .primary { background: #3b82f6; color: white; }
    .secondary { background: #263244; color: #dbeafe; border: 1px solid #3b4a61; }
    code { background: #111827; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
<main>
  <div class="card">
    <h1>安装 HTTPS 解密根证书</h1>
    <p>当前代理开启了 HTTPS 解密抓包。iOS 需要安装并完全信任根证书后，才能访问被解密的 HTTPS 请求。</p>
    $fingerprintHtml
    <a class="button primary" href="/__proxy/ca.cer">下载根证书</a>
    <ol>
      <li>点击“下载根证书”，在 iOS 弹出的描述文件提示中允许下载。</li>
      <li>进入 <code>设置 → 通用 → VPN 与设备管理</code> 安装描述文件。</li>
      <li>再进入 <code>设置 → 通用 → 关于本机 → 证书信任设置</code>，打开完全信任。</li>
      <li>回到目标 App 或浏览器，重新发起请求。</li>
    </ol>
    <p>说明：iOS 不允许网页或普通 App 自动完成“完全信任根证书”，也不稳定允许网页直接跳转到证书设置页。请按上面的系统路径手动进入设置并确认。</p>
  </div>
</main>
</body>
</html>
''';
  }

  static String _mitmCertificatePortalDisabledHtml({
    required bool remoteClient,
    required bool mitmEnabled,
  }) {
    final message = mitmEnabled && remoteClient
        ? '当前只解密本机请求，局域网设备不会被 HTTPS 解密，因此暂不提供证书下载。若要抓手机 HTTPS 请求，请在代理设置中开启“解密局域网设备”。'
        : '当前代理未开启 HTTPS 解密抓包，不需要安装根证书。开启 HTTPS 解密抓包后，再打开本页面即可下载证书。';
    return '''
<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Deployment 代理证书</title>
  <style>
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f1117; color: #f1f5f9; }
    main { max-width: 720px; margin: 0 auto; padding: 28px 20px; }
    .card { background: #171b23; border: 1px solid #303746; border-radius: 16px; padding: 20px; }
    h1 { font-size: 22px; margin: 0 0 12px; }
    p { color: #cbd5e1; line-height: 1.55; }
  </style>
</head>
<body>
<main>
  <div class="card">
    <h1>当前不需要安装证书</h1>
    <p>$message</p>
  </div>
</main>
</body>
</html>
''';
  }

  bool _isProxyAuthorized(List<String> lines) {
    if (_authPassword.isEmpty) return true;
    final expected = base64Encode(utf8.encode('$_authUsername:$_authPassword'));
    for (final line in lines.skip(1)) {
      final sep = line.indexOf(':');
      if (sep <= 0) continue;
      final name = line.substring(0, sep).trim().toLowerCase();
      if (name != 'proxy-authorization') continue;
      final value = line.substring(sep + 1).trim();
      final parts = value.split(RegExp(r'\s+'));
      if (parts.length != 2 || parts.first.toLowerCase() != 'basic') {
        return false;
      }
      return parts[1] == expected;
    }
    return false;
  }

  bool _isProxyTargetAllowed(String targetHost) {
    if (_isMitmTrustProbeHost(targetHost)) return true;
    if (_proxyAllowHosts.isEmpty) return true;
    final host = targetHost.toLowerCase();
    for (final pattern in _proxyAllowHosts) {
      final p = pattern.trim().toLowerCase();
      if (p.isEmpty) continue;
      if (p == '*') return true;
      if (p.startsWith('.')) {
        if (host.endsWith(p) || host == p.substring(1)) return true;
      } else if (host == p || host.endsWith('.$p')) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _writeProxyAuthRequired(Socket client) async {
    try {
      client.write(
        'HTTP/1.1 407 Proxy Authentication Required\r\n'
        'Proxy-Authenticate: Basic realm="Deployment Proxy"\r\n'
        'Connection: close\r\n'
        'Content-Length: 0\r\n\r\n',
      );
      await client.flush();
    } catch (_) {}
  }

  static String _formatTunnelErrors(_ProxyClientCtx ctx) {
    final parts = <String>[];
    final clientError = ctx.clientError;
    if (clientError != null) {
      parts.add('client_error=$clientError');
    }
    final upstreamError = ctx.upstreamError;
    if (upstreamError != null) {
      parts.add('upstream_error=$upstreamError');
    }
    return parts.isEmpty ? '' : ' | ${parts.join(' ')}';
  }
}

SecurityContext _defaultEncryptedProxySecurityContext() {
  final context = SecurityContext();
  context.useCertificateChainBytes(utf8.encode(_embeddedProxyCertificatePem));
  context.usePrivateKeyBytes(utf8.encode(_embeddedProxyPrivateKeyPem));
  return context;
}

const _embeddedProxyCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIICxjCCAa4CCQDlTLa123+EVTANBgkqhkiG9w0BAQsFADAlMSMwIQYDVQQDDBpE
ZXBsb3ltZW50IEVuY3J5cHRlZCBQcm94eTAeFw0yNjA1MTExNzM2MTNaFw0zNjA1
MDgxNzM2MTNaMCUxIzAhBgNVBAMMGkRlcGxveW1lbnQgRW5jcnlwdGVkIFByb3h5
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq3olkXoGu4H+s7s+PdUW
lgBV+QVJ9zOl5cyFjhYH75fCtzG8BXAV5QZbir7UtizAQvkz7LrxVaG4TgzuyThH
b811JtyWnXb7ynfK1afYNicUViDL73xIJZw8+4L4vvVnmPv9wih0HK+fr7GHRwp3
2ixAOuMYI81EPoAjoQj50/nCNDmkeCRm2jzP57HNoOfouuPr2e+l9NIIRxwfupy8
iwrhs8WQi5hLszmdM42drgxwIdYo0dmS2rKosXxLsCJ+qAe+ZSPNuRguafLOSeTi
QM8lX+GFrw7eK6R3gqtXJ3/V6L70TDRpAhwEWEgN024FJLs7xUPp5oX9jHAucQt7
JQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQAx/NTX5stwZBfK1OapxFdq8Repsxr9
Bjl8TlE/ipqc0dlkxs600JsJwAjC3/9CSB2xRy4+9H7iAXFIJpPd6GxVP8cz1JN/
Q3xcRyhprM5ewG9NEviAOT9DBuTgtTWSpy7QILa7F868L+yn9zpeWnXTNxs16VY+
ug/Tn+rvvcdOLJ+KYjIDyN26MEr3vOj4klK5JZE/obBt2YmCIBTLxINHpCYnOYMi
gkG44P6MdHo70YqzXhW+y2u2Ly3ewEdaDtgRGotTr9K/6qZ5KcyU05ySVDIxXxa7
4cWZa3NLRaZr/BIco1mFiO/3cvASqPozjM5JWxCi7ncV6ihnfDxsik/h
-----END CERTIFICATE-----
''';

const _embeddedProxyPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCreiWRega7gf6z
uz491RaWAFX5BUn3M6XlzIWOFgfvl8K3MbwFcBXlBluKvtS2LMBC+TPsuvFVobhO
DO7JOEdvzXUm3JaddvvKd8rVp9g2JxRWIMvvfEglnDz7gvi+9WeY+/3CKHQcr5+v
sYdHCnfaLEA64xgjzUQ+gCOhCPnT+cI0OaR4JGbaPM/nsc2g5+i64+vZ76X00ghH
HB+6nLyLCuGzxZCLmEuzOZ0zjZ2uDHAh1ijR2ZLasqixfEuwIn6oB75lI825GC5p
8s5J5OJAzyVf4YWvDt4rpHeCq1cnf9XovvRMNGkCHARYSA3TbgUkuzvFQ+nmhf2M
cC5xC3slAgMBAAECggEAEeeYIp+GMm/5Y1Tqw9QLHrB8SZsmxPwMl3kKfPKJ85d6
ClzUEBFLB/Xo+wy/8yGrFZMlu9MtPc68CtJI4JPSyba/Q8aGp3x0AAkQEc0Lw2PD
ONcF1ES618p/h5d+V5oSLiQps+s7bH9eAh9cS6upJgu2zS9HJv3Y4VnJ3pesVliz
D+PPQWSVbR1Mygz2Wh9tISkYP6QjRaMz+K3/oWFXPMhgp66eZMcjw1ob1Fha72Nk
NWevGBZuAgE+U/CHi8NP6LMUb/0ihwLhignC6rbfJFvHbQ1yDnFtzupTAiBlzxWu
fxamQnBOoRc+FK8sJKqwn9hQDy4ahcW9hpUduc4+5QKBgQDTgm93h05aEbvkRsYu
vpMxD5KCrOjdWv/7BxAja9K2KEtjCmztb2SKaDb9A0K82/nPPDi9SX+E/KrsmI4G
5GiVyaC2VNIEe4aXhSCN24EBlCeoiYmz+XolrJSpyFXCxkh6nqY7ZLZDA7v5FzOB
YxVXECl/TRl9IYwHAoBpHuVS9wKBgQDPjAKMN7wrK/0DvsiDuI08OuQeltio4pqD
BdZTy/c7KtVwOAUFmN8TKorxWjkF3dhIgOju47BIIvflzaD14tnoa12ZU3zAXmZc
FmqWwb+mpGO1OKAOBOkSaxRe3RxhohFTZ4h955Vz3g6rct05lKQNHtJ1vsDTgNeS
V2iOx4G/wwKBgEAZFli965PGLg/XFvZRkN/cXUU2y3dRvaPAlzZ01a2Ydog0P6CR
EoITZR62H0KG06TnFjbfEEMoI1CCRwB1tfA243p+KAttt/MxSBVVgToOQRqFW/Lr
1wWV0JPHf54AYzSt4ai8M7QJbKznSBedBHmXD0xh/Ch8wyfYrTuuPkcvAoGBAIT+
5zMLFB1mFsArpTojLP4Hjt67MyMl8nU7bFhOP6M+k39RpoYrq+cQP/DhK+FCg7IS
STGr3e6b2db8qcRnFdQF2PjDsxFibJ1eD/eDOFiExw/9tTLGmsQesfMIJYO64vdb
RO/JUs/o3+WluXWIdoeh1KN3FQFzcrBoKqwz1EUZAoGAL6o7sv+krTQ/3izoy/iv
BaR0/fShREjndPnZyXYY6nnRGEqX805WlMqvvq4VPSwTsPfl63rOaPgk0ebdczz0
vm4C7PAmzZc7BPDV7jrzeaJWQ9fGyiY5TyyGBQ2CjkShM0EZugsVc4v+Fp1DpMmo
MbyXI6q8fQ9iJZHVmDPg784=
-----END PRIVATE KEY-----
''';

class _HttpMessageHead {
  const _HttpMessageHead({
    required this.rawBytes,
    required this.startLine,
    required this.headers,
    required this.contentLength,
    required this.chunked,
    required this.connectionClose,
  });

  final List<int> rawBytes;
  final String startLine;
  final List<ProxyHeader> headers;
  final int? contentLength;
  final bool chunked;
  final bool connectionClose;

  static _HttpMessageHead? fromBytes(List<int> rawBytes) {
    final text = utf8.decode(rawBytes, allowMalformed: true);
    final headerText = text.endsWith('\r\n\r\n')
        ? text.substring(0, text.length - 4)
        : text;
    final lines = headerText.split('\r\n');
    if (lines.isEmpty || lines.first.isEmpty) return null;
    final headers = HttpForwardProxyServer._parseHeaderLines(lines.skip(1));
    final contentLength = _headerValue(headers, 'content-length');
    final transferEncoding = _headerValue(headers, 'transfer-encoding');
    final connection = _headerValue(headers, 'connection');
    return _HttpMessageHead(
      rawBytes: rawBytes,
      startLine: lines.first,
      headers: headers,
      contentLength: contentLength == null ? null : int.tryParse(contentLength),
      chunked: transferEncoding?.toLowerCase().contains('chunked') == true,
      connectionClose: connection?.toLowerCase().contains('close') == true,
    );
  }

  static String? _headerValue(List<ProxyHeader> headers, String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.name.toLowerCase() == lower) return h.value;
    }
    return null;
  }
}

class _HttpMessageReader {
  _HttpMessageReader(Stream<List<int>> source) {
    _subscription = source.listen(
      (chunk) {
        if (chunk.isNotEmpty) {
          _buffer.addAll(chunk);
          _notify();
        }
      },
      onDone: () {
        _done = true;
        _notify();
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _done = true;
        _notify();
      },
      cancelOnError: false,
    );
  }

  final List<int> _buffer = [];
  late final StreamSubscription<List<int>> _subscription;
  Completer<void>? _waiter;
  bool _done = false;
  Object? _error;

  Future<void> cancel() => _subscription.cancel();

  Future<_HttpMessageHead?> readHead() async {
    while (true) {
      _throwIfError();
      final end = _headerEnd(_buffer);
      if (end >= 0) {
        final raw = _buffer.sublist(0, end);
        _buffer.removeRange(0, end);
        return _HttpMessageHead.fromBytes(raw);
      }
      if (_done) {
        if (_buffer.isEmpty) return null;
        final raw = List<int>.from(_buffer);
        _buffer.clear();
        return _HttpMessageHead.fromBytes(raw);
      }
      await _waitForData();
    }
  }

  Future<List<int>?> readLine({required bool includeDelimiter}) async {
    while (true) {
      _throwIfError();
      final end = _lineEnd(_buffer);
      if (end >= 0) {
        final take = includeDelimiter ? end : end - 2;
        final raw = _buffer.sublist(0, take);
        _buffer.removeRange(0, end);
        return raw;
      }
      if (_done) {
        if (_buffer.isEmpty) return null;
        final raw = List<int>.from(_buffer);
        _buffer.clear();
        return raw;
      }
      await _waitForData();
    }
  }

  Future<List<int>?> readExactly(int count) async {
    final out = <int>[];
    var remaining = count;
    while (remaining > 0) {
      final part = await readUpTo(remaining);
      if (part == null || part.isEmpty) return out.isEmpty ? null : out;
      out.addAll(part);
      remaining -= part.length;
    }
    return out;
  }

  Future<List<int>?> readUpTo(int count) async {
    while (_buffer.isEmpty) {
      _throwIfError();
      if (_done) return null;
      await _waitForData();
    }
    final take = _buffer.length < count ? _buffer.length : count;
    final raw = _buffer.sublist(0, take);
    _buffer.removeRange(0, take);
    return raw;
  }

  Future<void> _waitForData() {
    final waiter = _waiter ??= Completer<void>();
    return waiter.future;
  }

  void _notify() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;
    _waiter = null;
    waiter.complete();
  }

  void _throwIfError() {
    final error = _error;
    if (error != null) throw error;
  }

  static int _headerEnd(List<int> bytes) {
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

  static int _lineEnd(List<int> bytes) {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x0d && bytes[i + 1] == 0x0a) {
        return i + 2;
      }
    }
    return -1;
  }
}

/// 每个客户端连接一条 [Socket] 订阅；隧道阶段把后续字节写入 [upstream]，结束时双方流都关闭再 [complete] [tunnelDone]。
class _ProxyClientCtx {
  bool dispatchScheduled = false;
  bool inTunnel = false;

  /// 当前转发会话标签，用于 `FWD …` 状态行（CONNECT / HTTP）。
  String? forwardLabel;
  Socket? upstream;
  StreamSubscription<List<int>>? upstreamSub;
  bool upstreamReadDone = false;
  bool clientTunnelReadDone = false;
  String? upstreamError;
  String? clientError;
  Completer<void>? tunnelDone;

  void checkTunnelDone() {
    final c = tunnelDone;
    if (upstreamReadDone &&
        clientTunnelReadDone &&
        c != null &&
        !c.isCompleted) {
      c.complete();
    }
  }
}

class _MitmClientTlsBridge {
  _MitmClientTlsBridge({
    required this.serverSide,
    required this.clientSide,
    required this.outerClient,
  });

  final Socket serverSide;
  final Socket clientSide;
  final Socket outerClient;
  late final StreamSubscription<List<int>> clientSideSub;
  int _pendingOuterFlushes = 0;
  Completer<void>? _idleCompleter;
  final Completer<void> _clientSideDone = Completer<void>();

  void forwardToOuterClient(List<int> chunk) {
    if (chunk.isEmpty) return;
    _pendingOuterFlushes++;
    outerClient.add(chunk);
    unawaited(
      outerClient.flush().catchError((_) {}).whenComplete(() {
        _pendingOuterFlushes--;
        if (_pendingOuterFlushes == 0) {
          final idle = _idleCompleter;
          _idleCompleter = null;
          if (idle != null && !idle.isCompleted) idle.complete();
        }
      }),
    );
  }

  void markClientSideDone() {
    if (!_clientSideDone.isCompleted) _clientSideDone.complete();
  }

  Future<void> close() async {
    try {
      await serverSide.close();
    } catch (_) {}
    try {
      await _clientSideDone.future.timeout(const Duration(milliseconds: 250));
    } catch (_) {}
    try {
      if (_pendingOuterFlushes > 0) {
        final idle = _idleCompleter ??= Completer<void>();
        await idle.future.timeout(const Duration(milliseconds: 250));
      }
    } catch (_) {}
    try {
      await clientSideSub.cancel();
    } catch (_) {}
    try {
      await clientSide.close();
    } catch (_) {}
  }
}
