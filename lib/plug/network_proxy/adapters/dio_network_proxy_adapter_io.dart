import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../core/http_client_proxy_apply.dart';
import '../core/network_proxy_state.dart';

void attachNetworkProxyToDio(Dio dio, NetworkProxyState state) {
  if (!state.shouldUseClientProxy) return;
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      applyProxyClientToHttpClient(client, state.client);
      return client;
    },
  );
}
