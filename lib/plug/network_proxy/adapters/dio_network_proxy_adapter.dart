import 'package:dio/dio.dart';

import 'dio_network_proxy_adapter_io.dart'
    if (dart.library.html) 'dio_network_proxy_adapter_stub.dart'
    as impl;
import '../core/network_proxy_state.dart';

void attachNetworkProxyToDio(Dio dio, NetworkProxyState state) {
  impl.attachNetworkProxyToDio(dio, state);
}
