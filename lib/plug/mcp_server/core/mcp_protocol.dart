// MCP / JSON-RPC 协议相关的纯数据类型与常量；不依赖 Flutter 或 dart:io。

/// 本服务器宣告支持的 MCP 协议版本（Streamable HTTP）。
const String kMcpProtocolVersion = '2025-06-18';

const String kMcpServerName = 'Deployment Browser MCP';
const String kMcpServerVersion = '1.0.0';

/// 工具调用结果。[errorMessage] 非空表示这是一次「工具级错误」
/// （在 MCP 里以 `isError: true` 回传，而不是 JSON-RPC error）。
class McpCallOutcome {
  const McpCallOutcome.ok(this.data) : errorMessage = null;
  const McpCallOutcome.error(this.errorMessage) : data = null;

  final Object? data;
  final String? errorMessage;

  bool get isError => errorMessage != null;
}

/// 按明文令牌串解析出 token id；返回 null 表示鉴权失败。
typedef McpTokenResolver = String? Function(String? presentedSecret);

/// 执行某个工具：传入已鉴权的 token id、工具名与参数，返回结果。
typedef McpToolInvoker = Future<McpCallOutcome> Function(
  String tokenId,
  String toolName,
  Map<String, dynamic> arguments,
);

/// 日志回调（可选）。
typedef McpServerLog = void Function(String message);
