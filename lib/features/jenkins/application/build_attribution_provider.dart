import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build_attribution.dart';

/// 全进程共享的构建归属台账。
///
/// 发版 UI 与内嵌 MCP 服务都从这里读，两个通道才不会把同一条构建认成各自的。
final buildAttributionRegistryProvider = Provider<BuildAttributionRegistry>(
  (_) => BuildAttributionRegistry(),
);
