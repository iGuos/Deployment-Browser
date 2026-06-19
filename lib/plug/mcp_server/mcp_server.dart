/// MCP 接口插件的对外（web 安全）入口：仅导出不依赖 dart:io 的 core 类型。
///
/// dart:io 实现（[McpHttpServer]）只由 application/mcp_server_binding_io.dart 引用，
/// web 构建走 stub，不会触达 dart:io。
library;

export 'core/mcp_protocol.dart';
export 'core/mcp_server_config.dart';
export 'core/mcp_server_state_codec.dart';
export 'core/mcp_token.dart';
export 'core/mcp_tool_specs.dart';
