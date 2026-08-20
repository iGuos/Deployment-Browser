import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('triggerBuild uses buildWithParameters with form body and Referer', () async {
    RequestOptions? captured;
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
                  'crumb': 'test-crumb',
                },
              ),
            );
            return;
          }
          captured = options;
          handler.resolve(
            Response<void>(
              requestOptions: options,
              statusCode: 201,
              headers: Headers.fromMap({
                'location': ['http://jenkins.example/queue/item/42/'],
              }),
            ),
          );
        },
      ),
    );

    final api = JenkinsApi(dio);
    final queueUrl = (await api.triggerBuild(
      'team/app',
      parameters: {'SERVICE': 'orders'},
    )).location;

    expect(queueUrl, 'http://jenkins.example/queue/item/42/');
    expect(captured, isNotNull);
    expect(captured!.method, 'POST');
    expect(captured!.uri.path, '/job/team/job/app/buildWithParameters');
    expect(captured!.queryParameters['delay'], '0sec');
    final referer = captured!.headers['Referer'];
    expect(referer, 'http://jenkins.example/job/team/job/app/');
    expect(captured!.data, isA<Map>());
    final body = captured!.data as Map;
    expect(body['SERVICE'], 'orders');
    expect(body['Jenkins-Crumb'], 'test-crumb');
    expect(captured!.responseType, ResponseType.plain);
  });

  test('403 then success clears crumb and retries', () async {
    var postCalls = 0;
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
                  'crumb': 'crumb-${options.uri}',
                },
              ),
            );
            return;
          }
          postCalls++;
          if (postCalls == 1) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 403,
                data: '<html>forbidden</html>',
              ),
            );
          } else {
            handler.resolve(
              Response<void>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'location': ['http://jenkins.example/queue/item/99/'],
                }),
              ),
            );
          }
        },
      ),
    );

    final api = JenkinsApi(dio);
    final queueUrl = (await api.triggerBuild('job/a', parameters: {'X': 'y'})).location;
    expect(postCalls, 2);
    expect(queueUrl, contains('/queue/item/99/'));
  });

  test('400 on buildWithParameters falls back to Pipeline POST /build json=', () async {
    var posts = 0;
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
          if (path.contains('crumbIssuer')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'crumbRequestField': 'Jenkins-Crumb',
                  'crumb': 'c',
                },
              ),
            );
            return;
          }
          posts++;
          if (path.contains('buildWithParameters')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 400,
                data: 'Bad Request',
              ),
            );
            return;
          }
          if (path.endsWith('/build')) {
            expect(options.method, 'POST');
            final data = options.data;
            expect(data, isA<Map>());
            final jsonStr = (data as Map)['json'];
            expect(jsonStr, isA<String>());
            expect(jsonStr, contains('SERVICE'));
            expect(jsonStr, contains('orders'));
            handler.resolve(
              Response<void>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'location': ['http://jenkins.example/queue/item/77/'],
                }),
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
              error: 'unexpected path=$path method=${options.method}',
            ),
          );
        },
      ),
    );

    final api = JenkinsApi(dio);
    final queueUrl = (await api.triggerBuild(
      'team/app',
      parameters: {'SERVICE': 'orders'},
    )).location;
    expect(queueUrl, 'http://jenkins.example/queue/item/77/');
    expect(posts, greaterThanOrEqualTo(2));
  });

  test('Pipeline jobClass hint skips buildWithParameters and goes straight to POST /build', () async {
    var probedBuildWithParameters = false;
    var posts = 0;
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
          if (path.contains('crumbIssuer')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'crumbRequestField': 'Jenkins-Crumb',
                  'crumb': 'c',
                },
              ),
            );
            return;
          }
          if (path.contains('buildWithParameters')) {
            probedBuildWithParameters = true;
          }
          posts++;
          if (path.endsWith('/build')) {
            handler.resolve(
              Response<void>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'location': ['http://jenkins.example/queue/item/55/'],
                }),
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
              error: 'unexpected probe to ${options.method} $path',
            ),
          );
        },
      ),
    );

    final api = JenkinsApi(dio);
    final queueUrl = (await api.triggerBuild(
      'team/app',
      parameters: {'SERVICE': 'orders'},
      jobClass: 'org.jenkinsci.plugins.workflow.job.WorkflowJob',
    )).location;
    expect(queueUrl, contains('/queue/item/55/'));
    expect(probedBuildWithParameters, isFalse,
        reason: '已知是 Pipeline 时不应再探测 buildWithParameters');
    expect(posts, 1);
  });

  test('successful strategy is cached: 2nd trigger of same job no longer probes 400', () async {
    var posts = 0;
    var firstRunFinished = false;

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
          if (path.contains('crumbIssuer')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'crumbRequestField': 'Jenkins-Crumb',
                  'crumb': 'c',
                },
              ),
            );
            return;
          }
          posts++;
          if (!firstRunFinished && path.contains('buildWithParameters')) {
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 400,
                data: 'Bad Request',
              ),
            );
            return;
          }
          if (path.endsWith('/build')) {
            handler.resolve(
              Response<void>(
                requestOptions: options,
                statusCode: 201,
                headers: Headers.fromMap({
                  'location': ['http://jenkins.example/queue/item/${100 + posts}/'],
                }),
              ),
            );
            return;
          }
          // 第二次 buildWithParameters 不应再被探测到 —— 出现即测试失败
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.unknown,
              error: 'unexpected probe to ${options.method} $path on cached run',
            ),
          );
        },
      ),
    );

    final api = JenkinsApi(dio);

    await api.triggerBuild('team/app', parameters: {'SERVICE': 'orders'});
    final probeCount = posts;
    expect(probeCount, greaterThanOrEqualTo(2),
        reason: '首次触发应有探测过程');

    firstRunFinished = true;
    final queueUrl = (await api.triggerBuild('team/app', parameters: {'SERVICE': 'orders'})).location;

    expect(queueUrl, contains('/queue/item/'));
    expect(posts - probeCount, 1,
        reason: '第二次触发应直接命中 POST /build，不再发出 400 探测请求');
  });
}
