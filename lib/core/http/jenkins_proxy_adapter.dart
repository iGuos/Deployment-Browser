import 'package:dio/dio.dart';

import '../../plug/network_proxy/network_proxy_state.dart';
import 'jenkins_proxy_adapter_io.dart' if (dart.library.html) 'jenkins_proxy_adapter_stub.dart'
    as impl;

void attachJenkinsNetworkProxy(Dio dio, NetworkProxyState state) =>
    impl.attachJenkinsNetworkProxy(dio, state);
