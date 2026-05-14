import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetchQueueItem returns null on non-200', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://jenkins.example',
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 404,
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final api = JenkinsApi(dio);
    final item = await api.fetchQueueItem('http://jenkins.example/queue/item/77/');
    expect(item, isNull);
  });

  test('fetchQueueItem parses why before executable assigned', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://jenkins.example',
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.path, '/queue/item/77/api/json');
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{
                'id': 77,
                'cancelled': false,
                'why': 'Waiting for next available executor',
              },
            ),
          );
        },
      ),
    );
    final api = JenkinsApi(dio);
    final item = await api.fetchQueueItem('http://jenkins.example/queue/item/77/');
    expect(item, isNotNull);
    expect(item!.id, 77);
    expect(item.cancelled, isFalse);
    expect(item.executable, isNull);
    expect(item.why, 'Waiting for next available executor');
    expect(item.isStarted, isFalse);
    expect(item.isWaiting, isTrue);
  });

  test('fetchQueueItem reports executable once Jenkins assigns build', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://jenkins.example',
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <String, dynamic>{
                'id': 77,
                'cancelled': false,
                'executable': {
                  'number': 128,
                  'url': 'http://jenkins.example/job/team/job/app/128/',
                },
              },
            ),
          );
        },
      ),
    );
    final api = JenkinsApi(dio);
    final item = await api.fetchQueueItem('http://jenkins.example/queue/item/77/');
    expect(item, isNotNull);
    expect(item!.isStarted, isTrue);
    expect(item.executable?.number, 128);
  });
}
