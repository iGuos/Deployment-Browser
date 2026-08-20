import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录每次 POST 的路径，并按 [respond] 决定状态码 / Location 头。
class _FakeJenkins {
  _FakeJenkins(this.respond);

  /// 返回 (statusCode, location, body)
  final ({int code, String? location, String? body}) Function(String path)
  respond;

  final List<String> posts = [];

  Dio build() {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://jenkins.example',
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final path = options.uri.path;
          // crumb 探测：直接 404，让 API 走「无 crumb」分支
          if (path.contains('crumbIssuer')) {
            handler.resolve(
              Response<dynamic>(requestOptions: options, statusCode: 404),
            );
            return;
          }
          if (options.method == 'POST') posts.add(path);
          final r = respond(path);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: r.code,
              data: r.body ?? '',
              headers: r.location == null
                  ? null
                  : Headers.fromMap({
                      'location': [r.location!],
                    }),
            ),
          );
        },
      ),
    );
    return dio;
  }
}

void main() {
  test('buildWithParameters 连续 400 时记录每次尝试，并暴露最终命中的策略', () async {
    final fake = _FakeJenkins((path) {
      if (path.endsWith('/buildWithParameters')) {
        return (
          code: 400,
          location: null,
          body: 'Nothing is submitted\n  at hudson.model...',
        );
      }
      // Pipeline 的 json=/build 路径：302 回任务页，**不给队列项地址**
      return (
        code: 302,
        location: 'http://jenkins.example/job/(dev)%20app/',
        body: null,
      );
    });
    final api = JenkinsApi(fake.build());

    final result = await api.triggerBuild(
      '(dev) app',
      parameters: const {'SERVICE': 'admin-web'},
    );

    // 策略 0-3 都是 buildWithParameters（400），4 是 build（302 命中）
    expect(result.strategy, 4);
    expect(result.endpoint, 'build');
    expect(result.statusCode, 302);
    expect(result.attempts.length, 5);
    expect(
      result.attempts.take(4).map((a) => a.endpoint),
      everyElement('buildWithParameters'),
    );
    expect(result.attempts.take(4).map((a) => a.statusCode), everyElement(400));
    // 400 的响应体片段留在诊断里（仅本机日志用）
    expect(result.attempts.first.bodySnippet, contains('Nothing is submitted'));
    expect(result.attempts.last.statusCode, 302);
    expect(result.attempts.last.bodySnippet, isNull);

    // 这正是 queueId 为 null 的根因：Location 不是队列项
    expect(result.isQueueItemLocation, isFalse);
    // locationPath 去掉了 scheme + host（路径保持 Jenkins 原样的百分号编码），
    // 可安全写日志
    expect(result.locationPath, '/job/(dev)%20app/');
    expect(result.failureSummary, contains('s0 buildWithParameters HTTP 400'));
  });

  test('buildWithParameters 直接成功时只有一次尝试，且拿到队列项地址', () async {
    final fake = _FakeJenkins(
      (_) => (
        code: 201,
        location: 'http://jenkins.example/queue/item/812/',
        body: null,
      ),
    );
    final api = JenkinsApi(fake.build());

    final result = await api.triggerBuild(
      'team/app',
      parameters: const {'SERVICE': 'admin-web'},
    );

    expect(result.strategy, 0);
    expect(result.endpoint, 'buildWithParameters');
    expect(result.attempts.single.statusCode, 201);
    expect(result.isQueueItemLocation, isTrue);
    expect(result.locationPath, '/queue/item/812/');
    expect(result.failureSummary, isEmpty);
  });
}
