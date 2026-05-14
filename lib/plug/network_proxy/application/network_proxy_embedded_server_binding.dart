import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_proxy_embedded_server_binding_io.dart'
    if (dart.library.html) 'network_proxy_embedded_server_binding_stub.dart'
    as impl;

/// 挂载内置代理生命周期；在 [DeploymentApp] 与独立代理窗口中 [watch] 一次即可。
final networkProxyEmbeddedServerBindingProvider = Provider<void>((ref) {
  impl.registerNetworkProxyEmbeddedServer(ref);
});
