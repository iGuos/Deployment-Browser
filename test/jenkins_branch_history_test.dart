import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JenkinsApi.fetchHistoricalParameterValues', () {
    test('extracts distinct values for the requested parameter', () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://jenkins.example',
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      RequestOptions? captured;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'builds': [
                    // 最新一次：BRANCH=feature/x，SERVICE=api
                    {
                      'actions': [
                        {
                          'parameters': [
                            {'name': 'BRANCH', 'value': 'feature/x'},
                            {'name': 'SERVICE', 'value': 'api'},
                          ],
                        },
                      ],
                    },
                    // 上一次：BRANCH=main
                    {
                      'actions': [
                        {
                          'parameters': [
                            {'name': 'BRANCH', 'value': 'main'},
                          ],
                        },
                      ],
                    },
                    // 再之前：BRANCH=feature/x（重复，应去重，但顺序不变）
                    {
                      'actions': [
                        {
                          'parameters': [
                            {'name': 'BRANCH', 'value': 'feature/x'},
                          ],
                        },
                      ],
                    },
                    // 这条只有 SERVICE 参数：应被忽略
                    {
                      'actions': [
                        {
                          'parameters': [
                            {'name': 'SERVICE', 'value': 'web'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ),
            );
          },
        ),
      );

      final api = JenkinsApi(dio);
      final values = await api.fetchHistoricalParameterValues(
        'team/app',
        'BRANCH',
        count: 25,
      );

      expect(values, ['feature/x', 'main']);
      expect(captured?.uri.path, '/job/team/job/app/api/json');
      expect(
        captured?.queryParameters['tree'],
        'builds[actions[parameters[name,value]]]{0,25}',
      );
    });

    test('returns empty list when API errors out', () async {
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://jenkins.example',
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'boom',
            ),
            true,
          ),
        ),
      );
      final api = JenkinsApi(dio);

      final values = await api.fetchHistoricalParameterValues('app', 'BRANCH');
      expect(values, isEmpty);
    });
  });
}
