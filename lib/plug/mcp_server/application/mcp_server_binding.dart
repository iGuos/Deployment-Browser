import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mcp_server_binding_io.dart'
    if (dart.library.html) 'mcp_server_binding_stub.dart' as impl;

/// 宿主在根 widget `ref.watch(mcpServerBindingProvider)` 即可挂载 MCP 服务器生命周期。
final mcpServerBindingProvider = Provider<void>((ref) {
  impl.registerMcpEmbeddedServer(ref);
});
