import 'package:deployment/features/jenkins/data/jenkins_api.dart';
import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个把所有请求就地 resolve 掉的 Dio，[onGet] 按路径返回假数据。
Dio _fakeDio(
  Map<String, dynamic>? Function(RequestOptions options) onGet,
) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://jenkins.example',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final data = onGet(options);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: data == null ? 404 : 200,
            data: data ?? const <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('JenkinsBuild 解析 queueId，-1 归一化为 null', () {
    expect(JenkinsBuild.fromJson(const {'number': 8, 'queueId': 4321}).queueId, 4321);
    expect(JenkinsBuild.fromJson(const {'number': 8, 'queueId': -1}).queueId, isNull);
    expect(JenkinsBuild.fromJson(const {'number': 8}).queueId, isNull);
  });

  test('fetchQueueItemById 用相对路径拉队列项', () async {
    late String seenPath;
    final api = JenkinsApi(
      _fakeDio((options) {
        seenPath = options.uri.path;
        return const {
          'id': 4321,
          'cancelled': false,
          'executable': {
            'number': 128,
            'url': 'http://jenkins.example/job/team/job/app/128/',
          },
        };
      }),
    );
    final item = await api.fetchQueueItemById(4321);
    expect(seenPath, '/queue/item/4321/api/json');
    expect(item?.executable?.number, 128);
  });

  test('findBuildNumberByQueueId 在历史里精确命中对应构建，同项目多次发版不串号', () async {
    late Map<String, dynamic> seenQuery;
    final api = JenkinsApi(
      _fakeDio((options) {
        seenQuery = options.queryParameters;
        return const {
          'builds': [
            {'number': 130, 'queueId': 4323},
            {'number': 129, 'queueId': 4322},
            {'number': 128, 'queueId': 4321},
          ],
        };
      }),
    );

    expect(await api.findBuildNumberByQueueId('team/app', 4321), 128);
    expect(seenQuery['tree'], 'builds[number,queueId]{0,30}');
    expect(await api.findBuildNumberByQueueId('team/app', 4322), 129);
    expect(await api.findBuildNumberByQueueId('team/app', 4323), 130);
  });

  test('findBuildNumberByQueueId 找不到时返回 null（还没出队）', () async {
    final api = JenkinsApi(
      _fakeDio(
        (_) => const {
          'builds': [
            {'number': 128, 'queueId': 4321},
          ],
        },
      ),
    );
    expect(await api.findBuildNumberByQueueId('team/app', 9999), isNull);
  });

  test('构建历史查询带上 queueId 字段，供调用方对账', () async {
    final queries = <String>[];
    final api = JenkinsApi(
      _fakeDio((options) {
        queries.add(options.queryParameters['tree'] as String);
        return const {
          'builds': [
            {'number': 128, 'queueId': 4321},
          ],
        };
      }),
    );

    final history = await api.fetchBuildHistory('team/app', count: 5);
    expect(history.single.queueId, 4321);
    final releases = await api.fetchReleaseHistory('team/app', count: 5);
    expect(releases.single.build.queueId, 4321);
    expect(queries.every((q) => q.contains('queueId')), isTrue);
  });
}
