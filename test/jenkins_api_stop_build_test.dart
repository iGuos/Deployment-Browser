import 'package:deployment/core/http/jenkins_http_client.dart';
import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 给定一组对 (path, statusCode) 的 dio mock，按 path 后缀决定返回什么。
/// crumb 永远 200。
Dio _mockDio(Map<String, int> codes, {List<RequestOptions>? captured}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://jenkins.example',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.contains('crumbIssuer')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'crumbRequestField': 'Jenkins-Crumb',
                'crumb': 'crumb-123',
              },
            ),
          );
          return;
        }
        captured?.add(options);
        for (final entry in codes.entries) {
          if (options.path.endsWith(entry.key)) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: entry.value,
                data: '',
              ),
            );
            return;
          }
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 500,
            data: 'unmocked',
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  group('JenkinsApi.stopBuild', () {
    test('POST /stop with crumb + Referer returns on 200', () async {
      final captured = <RequestOptions>[];
      final dio = _mockDio({'/42/stop': 200}, captured: captured);
      final api = JenkinsApi(dio);

      await api.stopBuild('team/app', 42);

      expect(captured, hasLength(1));
      final r = captured.single;
      expect(r.method, 'POST');
      expect(r.uri.path, '/job/team/job/app/42/stop');
      expect(r.headers['Jenkins-Crumb'], 'crumb-123');
      expect(r.headers['Referer'], 'http://jenkins.example/job/team/job/app/');
    });

    test('falls back to /term when /stop returns 4xx', () async {
      final captured = <RequestOptions>[];
      final dio = _mockDio(
        {'/7/stop': 405, '/7/term': 200},
        captured: captured,
      );
      final api = JenkinsApi(dio);

      await api.stopBuild('app', 7);

      expect(captured.map((c) => c.uri.path), [
        '/job/app/7/stop',
        '/job/app/7/term',
      ]);
    });

    test('throws JenkinsException when both endpoints fail', () async {
      final dio = _mockDio({'/9/stop': 404, '/9/term': 404});
      final api = JenkinsApi(dio);

      expect(
        () => api.stopBuild('app', 9),
        throwsA(isA<JenkinsException>()),
      );
    });
  });
}
