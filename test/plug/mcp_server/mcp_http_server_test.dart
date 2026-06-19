import 'dart:convert';
import 'dart:io';

import 'package:deployment/plug/mcp_server/core/mcp_http_server.dart';
import 'package:deployment/plug/mcp_server/core/mcp_protocol.dart';
import 'package:deployment/plug/mcp_server/core/mcp_tool_specs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late McpHttpServer server;
  late int port;
  final invocations =
      <({String tokenId, String tool, Map<String, dynamic> args})>[];

  Future<Map<String, dynamic>> post(
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', port, '/mcp');
      req.headers.contentType = ContentType.json;
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return {
        'status': res.statusCode,
        'body': text.isEmpty ? null : jsonDecode(text),
      };
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    invocations.clear();
    server = McpHttpServer(
      tools: kMcpToolSpecs,
      resolveToken: (presented) => presented == 'secret-123' ? 'tok-1' : null,
      invoke: (tokenId, tool, args) async {
        invocations.add((tokenId: tokenId, tool: tool, args: args));
        if (tool == kToolListAccounts) {
          return const McpCallOutcome.ok({
            'accounts': [
              {'id': 'a1', 'name': 'demo'},
            ],
          });
        }
        return const McpCallOutcome.error('boom');
      },
    );
    port = await _freePort();
    await server.bind(address: InternetAddress.loopbackIPv4, port: port);
  });

  tearDown(() async => server.close());

  test('binds and serves tools/list', () async {
    final res = await post(
      {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
      token: 'secret-123',
    );
    expect(res['status'], 200);
    final tools = (res['body'] as Map)['result']['tools'] as List;
    expect(tools.length, kMcpToolSpecs.length);
    expect(
      tools.map((t) => t['name']),
      containsAll([
        kToolListAccounts,
        kToolTriggerBuild,
        kToolGetBuildStatus,
        kToolGetReleaseHistory,
      ]),
    );
  });

  test('rejects requests without a valid token (401)', () async {
    final res = await post(
      {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
      token: 'wrong',
    );
    expect(res['status'], 401);
    expect(invocations, isEmpty);
  });

  test('initialize echoes protocol version and advertises tools', () async {
    final res = await post(
      {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      },
      token: 'secret-123',
    );
    final result = (res['body'] as Map)['result'] as Map;
    expect(result['protocolVersion'], '2025-06-18');
    expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
    expect((result['serverInfo'] as Map)['name'], kMcpServerName);
  });

  test('tools/call routes to invoke and wraps structured content', () async {
    final res = await post(
      {
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'tools/call',
        'params': {'name': kToolListAccounts, 'arguments': <String, dynamic>{}},
      },
      token: 'secret-123',
    );
    expect(res['status'], 200);
    expect(invocations.single.tokenId, 'tok-1');
    expect(invocations.single.tool, kToolListAccounts);
    final result = (res['body'] as Map)['result'] as Map;
    expect(result['isError'], false);
    expect(result['structuredContent']['accounts'], isA<List>());
    final text = (result['content'] as List).first['text'] as String;
    expect(jsonDecode(text)['accounts'], isA<List>());
  });

  test('tool-level error surfaces as isError result, not JSON-RPC error',
      () async {
    final res = await post(
      {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': kToolListProjects,
          'arguments': {'accountId': 'x'},
        },
      },
      token: 'secret-123',
    );
    final result = (res['body'] as Map)['result'] as Map;
    expect(result['isError'], true);
    expect((result['content'] as List).first['text'], 'boom');
  });

  test('unknown method returns JSON-RPC -32601', () async {
    final res = await post(
      {'jsonrpc': '2.0', 'id': 3, 'method': 'no/such'},
      token: 'secret-123',
    );
    expect((res['body'] as Map)['error']['code'], -32601);
  });
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}
