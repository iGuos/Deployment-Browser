import 'package:dio/dio.dart';

import '../../plug/network_proxy/adapters/dio_network_proxy_adapter.dart';
import '../../plug/network_proxy/network_proxy_state.dart';

/// 将 [NetworkProxyState] 中的客户端代理应用到 [Dio]（非 Web）。
void attachJenkinsNetworkProxy(Dio dio, NetworkProxyState state) {
  attachNetworkProxyToDio(dio, state);
}
