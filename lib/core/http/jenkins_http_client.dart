import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../../plug/network_proxy/network_proxy_state.dart';
import '../utils/app_logger.dart';
import 'jenkins_proxy_adapter.dart';

/// Jenkins 鉴权方式。
enum JenkinsAuthKind { token, password }

/// Jenkins 凭证（用户名 + token 或 password）。
class JenkinsCredentials {
  const JenkinsCredentials({
    required this.username,
    required this.secret,
    required this.kind,
  });

  final String username;
  final String secret;
  final JenkinsAuthKind kind;

  String get basicAuthHeader {
    final raw = '$username:$secret';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }
}

/// 创建一个绑定到 [baseUrl] + [credentials] 的 Dio 客户端。
///
/// 关键定制：
/// - 自动 Basic Auth；
/// - **会话 Cookie**：Jenkins CSRF crumb 常与 `Set-Cookie` 会话绑定，仅带 Basic Auth 不带 Cookie
///   时 POST 会一直 **403**。此处挂 [CookieManager]，使 `/crumbIssuer` 与构建触发共用会话；
/// - `validateStatus` 放宽到 4xx 之外才抛错（让上层根据 status 判断）；
/// - 注入 `User-Agent` 与必要 header；
/// - 默认 30s 超时（实时日志拉取等长流另行设置）；
/// - 简洁日志拦截器（仅记录方法 + URL + status，避免泄露凭证）。
Dio buildJenkinsDio({
  required String baseUrl,
  required JenkinsCredentials credentials,
  NetworkProxyState networkProxy = NetworkProxyState.defaults,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration receiveTimeout = const Duration(seconds: 30),
  Duration sendTimeout = const Duration(seconds: 30),
}) {
  final normalized = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  final dio = Dio(
    BaseOptions(
      baseUrl: normalized,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      followRedirects: true,
      headers: {
        'User-Agent': 'Deployment-Tool/1.0 (Flutter)',
        'Accept': 'application/json, text/plain;q=0.8, */*;q=0.5',
        'Authorization': credentials.basicAuthHeader,
      },
      responseType: ResponseType.json,
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  dio.interceptors.add(CookieManager(CookieJar()));
  dio.interceptors.add(_LightLogInterceptor());
  attachJenkinsNetworkProxy(dio, networkProxy);
  return dio;
}

class _LightLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    appLogger.t('→ ${options.method} ${options.uri}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    appLogger.t('← ${response.statusCode} ${response.requestOptions.uri}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    appLogger.w(
      '✗ ${err.requestOptions.method} ${err.requestOptions.uri} · ${err.message}',
    );
    handler.next(err);
  }
}

/// 把 Dio 错误标准化为 [JenkinsException]，便于 UI 层统一处理。
JenkinsException toJenkinsException(Object error) {
  if (error is JenkinsException) return error;
  if (error is DioException) {
    final code = error.response?.statusCode;
    final body = error.response?.data;
    final bodyText = body is String ? body.trim() : null;
    final bodyHint = bodyText == null || bodyText.isEmpty
        ? null
        : bodyText.length > 500
        ? '${bodyText.substring(0, 500)}...'
        : bodyText;
    if (_isProxyCertificateRequired(error)) {
      return JenkinsException(
        message: 'HTTPS 解密抓包需要先在手机安装并完全信任根证书',
        statusCode: 428,
        cause: error,
        body: bodyText,
        proxyCertificateRequired: true,
      );
    }
    final hint = switch (code) {
      401 => '鉴权失败：请检查用户名 / Token / 密码',
      403 =>
        bodyHint == null
            ? '权限不足：当前用户无访问该资源的权限，或 Jenkins CSRF crumb 校验失败'
            : '权限不足 / CSRF 校验失败：$bodyHint',
      404 => '资源不存在：请确认 Jenkins URL 与 Job 路径',
      _ => null,
    };
    return JenkinsException(
      message: hint ?? error.message ?? '网络请求失败',
      statusCode: code,
      cause: error,
      body: bodyText,
    );
  }
  return JenkinsException(message: error.toString(), cause: error);
}

bool _isProxyCertificateRequired(DioException error) {
  if (error.response?.statusCode == 428) return true;
  final headers = error.response?.headers;
  if (headers?.value('x-deployment-proxy-certificate-required') == '1') {
    return true;
  }
  final err = error.error;
  if (err is Object) {
    final text = err.toString();
    return text.contains('Proxy failed to establish tunnel') &&
        text.contains('428 Certificate Required');
  }
  return false;
}

class JenkinsException implements Exception {
  JenkinsException({
    required this.message,
    this.statusCode,
    this.body,
    this.cause,
    this.proxyCertificateRequired = false,
  });

  final String message;
  final int? statusCode;
  final String? body;
  final Object? cause;
  final bool proxyCertificateRequired;

  @override
  String toString() => 'JenkinsException(${statusCode ?? '-'}): $message';
}
