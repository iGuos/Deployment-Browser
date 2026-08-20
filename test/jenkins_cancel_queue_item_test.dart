import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求并按 [code] 回响应；crumb 探测统一 404（走「无 crumb」分支）。
Dio _dio(int code, {void Function(RequestOptions)? onPost}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://jenkins.example',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.uri.path.contains('crumbIssuer')) {
          handler.resolve(
            Response<dynamic>(requestOptions: options, statusCode: 404),
          );
          return;
        }
        if (options.method == 'POST') onPost?.call(options);
        handler.resolve(
          Response<dynamic>(requestOptions: options, statusCode: code),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('cancelQueueItem 打到 /queue/cancelItem?id=，带 Referer', () async {
    RequestOptions? seen;
    final api = JenkinsApi(_dio(302, onPost: (o) => seen = o));

    expect(await api.cancelQueueItem(812), isTrue);
    expect(seen!.uri.path, '/queue/cancelItem');
    expect(seen!.queryParameters['id'], '812');
    expect(seen!.headers['Referer'], 'http://jenkins.example/');
    // 不能跟随重定向，否则会把 Jenkins 的 302 当成新请求打出去
    expect(seen!.followRedirects, isFalse);
  });

  test('队列项已出队 / 不存在时返回 false，交由上层改走 stopBuild', () async {
    final api = JenkinsApi(_dio(404));
    expect(await api.cancelQueueItem(999), isFalse);
  });

  test('200 / 204 也视为取消成功（不同 Jenkins 版本回码不一）', () async {
    expect(await JenkinsApi(_dio(200)).cancelQueueItem(1), isTrue);
    expect(await JenkinsApi(_dio(204)).cancelQueueItem(1), isTrue);
  });
}
