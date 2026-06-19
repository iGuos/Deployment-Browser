import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/mcp_http_server.dart';
import '../core/mcp_server_config.dart';
import '../core/mcp_tool_specs.dart';
import 'mcp_jenkins_service.dart';
import 'mcp_server_log_provider.dart';
import 'mcp_server_state_provider.dart';
import 'mcp_server_status_provider.dart';

/// 根据 [mcpServerConfigProvider] 启动 / 停止内置 MCP 服务器。
void registerMcpEmbeddedServer(Ref ref) {
  final service = McpJenkinsService(ref);
  void log(String m) => ref.read(mcpServerLogProvider.notifier).add(m);
  final status = ref.read(mcpServerStatusProvider.notifier);

  final server = McpHttpServer(
    tools: kMcpToolSpecs,
    resolveToken: (presented) =>
        ref.read(mcpServerConfigProvider).tokenIdForSecret(presented),
    invoke: (tokenId, name, args) => service.dispatch(
      tokenId: tokenId,
      toolName: name,
      arguments: args,
    ),
    onLog: log,
  );

  // 串行 close/bind，避免配置连续变更时并发竞态。
  Future<void> tail = Future.value();
  void enqueue(McpServerConfig c) {
    tail = tail.then((_) => _sync(server, c, log, status));
  }

  ref.listen<McpServerConfig>(
    mcpServerConfigProvider,
    (prev, next) => enqueue(next),
    fireImmediately: true,
  );
  ref.onDispose(() {
    unawaited(tail.then((_) => server.close()));
  });
}

Future<void> _sync(
  McpHttpServer server,
  McpServerConfig config,
  void Function(String) log,
  McpServerStatusNotifier status,
) async {
  final wasListening = server.isListening;
  await server.close();
  if (!config.shouldRun) {
    if (wasListening) log('MCP 接口：已停止监听。');
    status.setStopped();
    return;
  }
  if (config.tokens.isEmpty) {
    log('MCP 接口：已开启但尚未创建访问令牌，所有请求都会被拒绝。');
  }
  final addr = config.listenOnLoopbackOnly
      ? InternetAddress.loopbackIPv4
      : InternetAddress.anyIPv4;
  try {
    await server.bind(address: addr, port: config.port);
    status.setListening(
      port: config.port,
      loopbackOnly: config.listenOnLoopbackOnly,
    );
  } catch (e) {
    final reason = _friendlyBindError(e, config.port);
    log('MCP 接口：绑定失败（端口 ${config.port}）：$e');
    status.setError(
      port: config.port,
      loopbackOnly: config.listenOnLoopbackOnly,
      error: reason,
    );
  }
}

/// 把底层 [SocketException] 转成给用户看的简明原因（重点识别「端口被占用」）。
String _friendlyBindError(Object e, int port) {
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    // EADDRINUSE：macOS 48 / Linux 98 / Windows 10048。
    if (code == 48 || code == 98 || code == 10048) {
      return '端口 $port 已被占用，请换一个端口。';
    }
    // EACCES：低端口或权限不足。
    if (code == 13 || code == 10013) {
      return '端口 $port 没有权限绑定（尝试换用 1024 以上的端口）。';
    }
    final msg = e.osError?.message ?? e.message;
    return '端口 $port 绑定失败：$msg';
  }
  return '端口 $port 绑定失败：$e';
}
