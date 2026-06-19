import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_protocol.dart';
import 'mcp_tool_specs.dart';

/// 内嵌的 MCP 服务器（Streamable HTTP 传输）。
///
/// 单端点 `POST /mcp` 接收 JSON-RPC 请求并以 `application/json` 直接回响应
/// （本服务的工具都是请求-响应式，无需 SSE 流）。所有请求都必须在
/// `Authorization: Bearer <token>` 或 `X-MCP-Token: <token>` 头里携带有效令牌。
///
/// 本类只负责传输 + 协议 + 鉴权，具体工具执行委托给注入的 [invoke] 回调。
class McpHttpServer {
  McpHttpServer({
    required this.tools,
    required this.resolveToken,
    required this.invoke,
    this.onLog,
  });

  final List<McpToolSpec> tools;
  final McpTokenResolver resolveToken;
  final McpToolInvoker invoke;
  final McpServerLog? onLog;

  HttpServer? _server;

  bool get isListening => _server != null;

  void _log(String m) => onLog?.call(m);

  Future<void> bind({
    required InternetAddress address,
    required int port,
  }) async {
    await close();
    final server = await HttpServer.bind(address, port);
    _server = server;
    server.listen(
      _handleRequest,
      onError: (Object e, StackTrace st) => _log('MCP 服务器监听错误：$e'),
    );
    _log('MCP 接口已监听 ${address.address}:$port');
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    if (s == null) return;
    try {
      await s.close(force: true);
    } catch (_) {}
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final res = request.response;
    _applyCors(res);
    try {
      final method = request.method.toUpperCase();
      if (method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        await res.close();
        return;
      }
      if (method == 'GET') {
        // 不提供服务器主动推送的 SSE 流。
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.contentType = ContentType.text;
        res.write('MCP endpoint：请使用 POST /mcp');
        await res.close();
        return;
      }
      if (method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }

      // 鉴权
      final presented = _extractToken(request);
      final tokenId = resolveToken(presented);
      if (tokenId == null) {
        res.statusCode = HttpStatus.unauthorized;
        res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        _writeJson(res, {
          'jsonrpc': '2.0',
          'error': {'code': -32001, 'message': '缺少或无效的访问令牌'},
          'id': null,
        });
        await res.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      dynamic decoded;
      try {
        decoded = body.trim().isEmpty ? null : jsonDecode(body);
      } catch (_) {
        _writeJson(res, _rpcError(null, -32700, 'JSON 解析失败'));
        await res.close();
        return;
      }

      if (decoded is List) {
        // 批量请求
        final out = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final r = await _dispatchRpc(item, tokenId);
            if (r != null) out.add(r);
          }
        }
        if (out.isEmpty) {
          res.statusCode = HttpStatus.accepted;
          await res.close();
        } else {
          _writeJson(res, out);
          await res.close();
        }
        return;
      }

      if (decoded is! Map<String, dynamic>) {
        _writeJson(res, _rpcError(null, -32600, '无效的请求'));
        await res.close();
        return;
      }

      final result = await _dispatchRpc(decoded, tokenId);
      if (result == null) {
        // 通知（无 id），按 JSON-RPC 不返回响应体。
        res.statusCode = HttpStatus.accepted;
        await res.close();
        return;
      }
      _writeJson(res, result);
      await res.close();
    } catch (e, st) {
      _log('MCP 请求处理异常：$e\n$st');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  /// 处理单条 JSON-RPC 消息；返回 null 表示这是通知（不需要响应）。
  Future<Map<String, dynamic>?> _dispatchRpc(
    Map<String, dynamic> msg,
    String tokenId,
  ) async {
    final id = msg['id'];
    final isNotification = !msg.containsKey('id');
    final method = msg['method'] as String?;
    final params = msg['params'];

    if (method == null) {
      return isNotification ? null : _rpcError(id, -32600, '缺少 method');
    }

    switch (method) {
      case 'initialize':
        final clientVersion = params is Map<String, dynamic>
            ? params['protocolVersion'] as String?
            : null;
        return _rpcResult(id, {
          'protocolVersion': clientVersion ?? kMcpProtocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {
            'name': kMcpServerName,
            'version': kMcpServerVersion,
          },
        });

      case 'notifications/initialized':
      case 'initialized':
        return null; // 通知

      case 'ping':
        return _rpcResult(id, const {});

      case 'tools/list':
        return _rpcResult(id, {
          'tools': tools.map((t) => t.toJson()).toList(growable: false),
        });

      case 'tools/call':
        if (params is! Map<String, dynamic>) {
          return _rpcError(id, -32602, '缺少调用参数');
        }
        final name = params['name'] as String?;
        if (name == null || name.isEmpty) {
          return _rpcError(id, -32602, '缺少工具名 name');
        }
        final args = params['arguments'];
        final argMap = args is Map<String, dynamic>
            ? args
            : <String, dynamic>{};
        final knownTool = tools.any((t) => t.name == name);
        if (!knownTool) {
          return _rpcError(id, -32602, '未知工具：$name');
        }
        final outcome = await invoke(tokenId, name, argMap);
        return _rpcResult(id, _toolResultPayload(outcome));

      default:
        return isNotification ? null : _rpcError(id, -32601, '不支持的方法：$method');
    }
  }

  Map<String, dynamic> _toolResultPayload(McpCallOutcome outcome) {
    if (outcome.isError) {
      return {
        'content': [
          {'type': 'text', 'text': outcome.errorMessage ?? '调用失败'},
        ],
        'isError': true,
      };
    }
    final data = outcome.data;
    return {
      'content': [
        {'type': 'text', 'text': jsonEncode(data)},
      ],
      'structuredContent': data is Map<String, dynamic>
          ? data
          : {'result': data},
      'isError': false,
    };
  }

  String? _extractToken(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth != null && auth.isNotEmpty) {
      final m = RegExp(r'^\s*Bearer\s+(.+)$', caseSensitive: false)
          .firstMatch(auth);
      if (m != null) return m.group(1)?.trim();
      return auth.trim();
    }
    final custom = request.headers.value('x-mcp-token');
    if (custom != null && custom.isNotEmpty) return custom.trim();
    final q = request.uri.queryParameters['token'];
    if (q != null && q.isNotEmpty) return q.trim();
    return null;
  }

  void _applyCors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization, X-MCP-Token',
    );
  }

  /// 写 JSON 响应体；不改动 [HttpResponse.statusCode]（默认 200，鉴权失败等场景由调用方先行设置）。
  void _writeJson(HttpResponse res, Object payload) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(payload));
  }

  Map<String, dynamic> _rpcResult(Object? id, Object? result) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };

  Map<String, dynamic> _rpcError(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}
