import 'package:deployment/features/jenkins/domain/build_attribution.dart';
import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:flutter_test/flutter_test.dart';

JenkinsReleaseHistoryRow _row(
  int number,
  int timestamp, {
  Map<String, String> parameters = const {},
  String? userId,
}) => JenkinsReleaseHistoryRow(
  build: JenkinsBuild.fromJson({'number': number, 'timestamp': timestamp}),
  parameters: parameters,
  releasedByUserId: userId,
);

void main() {
  group('BuildAttributionRegistry', () {
    test('同一个构建号只有第一个认领者能拿到', () {
      final r = BuildAttributionRegistry();
      expect(r.claim('acct::job', 314, 'run-a'), isTrue);
      expect(r.claim('acct::job', 314, 'run-b'), isFalse);
      // 自己重复认领仍然成立（轮询会反复调用）
      expect(r.claim('acct::job', 314, 'run-a'), isTrue);
      expect(r.isHeldByOther('acct::job', 314, 'run-b'), isTrue);
      expect(r.isHeldByOther('acct::job', 314, 'run-a'), isFalse);
    });

    test('一个 owner 同一项目只持有一个号：认领新号会释放旧号', () {
      final r = BuildAttributionRegistry();
      r.claim('acct::job', 314, 'run-a');
      expect(r.claim('acct::job', 315, 'run-a'), isTrue);
      expect(r.numberOf('acct::job', 'run-a'), 315);
      // 314 已被释放，别人可以认领
      expect(r.claim('acct::job', 314, 'run-b'), isTrue);
    });

    test('release 后别人可以认领；不同项目互不影响', () {
      final r = BuildAttributionRegistry();
      r.claim('acct::job', 314, 'run-a');
      expect(r.claim('acct::other', 314, 'run-b'), isTrue);
      r.release('acct::job', 'run-a');
      expect(r.numberOf('acct::job', 'run-a'), isNull);
      expect(r.claim('acct::job', 314, 'run-b'), isTrue);
    });

    test('非法输入不登记', () {
      final r = BuildAttributionRegistry();
      expect(r.claim('acct::job', 0, 'run-a'), isFalse);
      expect(r.claim('acct::job', 314, ''), isFalse);
    });
  });

  group('matchBuildParameters', () {
    test('子集语义：快照多出来的键忽略', () {
      expect(
        matchBuildParameters(
          triggered: const {'SERVICE': 'admin-api'},
          snapshot: const {
            'SERVICE': 'admin-api',
            'GIT_BRANCH': 'main',
            'DEBUG': 'false',
          },
        ),
        ParameterMatch.matched,
      );
    });

    test('取值不同即判定不是本次触发', () {
      expect(
        matchBuildParameters(
          triggered: const {'SERVICE': 'admin-api'},
          snapshot: const {'SERVICE': 'admin-web'},
        ),
        ParameterMatch.mismatched,
      );
    });

    test('快照缺失 / 无参数可比时返回 unknown', () {
      expect(
        matchBuildParameters(
          triggered: const {'SERVICE': 'admin-api'},
          snapshot: const {},
        ),
        ParameterMatch.unknown,
      );
      expect(
        matchBuildParameters(
          triggered: const {},
          snapshot: const {'SERVICE': 'x'},
        ),
        ParameterMatch.unknown,
      );
    });
  });

  group('pickOwnBuild', () {
    test('只认触发之后、下界之上的构建', () {
      final rows = [
        _row(315, 1020000, parameters: const {'SERVICE': 'admin-api'}),
        _row(314, 1010000, parameters: const {'SERVICE': 'admin-api'}),
      ];
      final picked = pickOwnBuild(
        rows: rows,
        triggeredAt: 1015000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (_) => true,
      );
      expect(picked?.build.number, 315);
    });

    test('参数对不上的构建（同事手动触发）不会被认成自己的', () {
      final rows = [
        _row(315, 1020000, parameters: const {'SERVICE': 'admin-web'}),
      ];
      expect(
        pickOwnBuild(
          rows: rows,
          triggeredAt: 1020000,
          historyFloor: 314,
          triggeredParameters: const {'SERVICE': 'admin-api'},
          tryClaim: (_) => true,
        ),
        isNull,
      );
    });

    test('同一项目连续两次触发各拿一条，不串号', () {
      final registry = BuildAttributionRegistry();
      final rows = [
        _row(316, 1030000, parameters: const {'SERVICE': 'admin-api'}),
        _row(315, 1020000, parameters: const {'SERVICE': 'admin-api'}),
      ];
      final first = pickOwnBuild(
        rows: rows,
        triggeredAt: 1018000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (n) => registry.claim('k', n, 'trg-1'),
      );
      final second = pickOwnBuild(
        rows: rows,
        triggeredAt: 1025000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (n) => registry.claim('k', n, 'trg-2'),
      );
      expect(first?.build.number, 315);
      expect(second?.build.number, 316);
    });

    test('自己那条还没出现时返回 null，绝不认上一次的构建', () {
      final registry = BuildAttributionRegistry();
      final rows = [
        _row(315, 1020000, parameters: const {'SERVICE': 'admin-api'}),
      ];
      registry.claim('k', 315, 'trg-1');
      expect(
        pickOwnBuild(
          rows: rows,
          triggeredAt: 1025000,
          historyFloor: 314,
          triggeredParameters: const {'SERVICE': 'admin-api'},
          tryClaim: (n) => registry.claim('k', n, 'trg-2'),
        ),
        isNull,
      );
    });

    test('参数确实对上的优先于无法判断的', () {
      final rows = [
        // 号更小但快照缺参数（无法判断）
        _row(315, 1020000),
        _row(316, 1021000, parameters: const {'SERVICE': 'admin-api'}),
      ];
      final picked = pickOwnBuild(
        rows: rows,
        triggeredAt: 1019000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (_) => true,
      );
      expect(picked?.build.number, 316);
    });

    test('明确由别人触发的构建被排除（同参数的人工发版也不会串）', () {
      // 同事在 Jenkins 页面上用同一套参数手动发了一次，号还更小
      final rows = [
        _row(
          315,
          1020000,
          parameters: const {'SERVICE': 'admin-api'},
          userId: 'colleague',
        ),
        _row(
          316,
          1021000,
          parameters: const {'SERVICE': 'admin-api'},
          userId: 'me',
        ),
      ];
      final picked = pickOwnBuild(
        rows: rows,
        triggeredAt: 1019000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (_) => true,
        expectedUserId: 'ME',
      );
      expect(picked?.build.number, 316, reason: '登录名比对不区分大小写');
    });

    test('触发者解析不到时不排除（否则会把自己的构建判成别人的）', () {
      final rows = [
        _row(315, 1020000, parameters: const {'SERVICE': 'admin-api'}),
      ];
      final picked = pickOwnBuild(
        rows: rows,
        triggeredAt: 1019000,
        historyFloor: 314,
        triggeredParameters: const {'SERVICE': 'admin-api'},
        tryClaim: (_) => true,
        expectedUserId: 'me',
      );
      expect(picked?.build.number, 315);
    });

    test('容差窗口外的构建不认（时钟偏差以外）', () {
      final rows = [_row(315, 900000, parameters: const {'S': 'a'})];
      expect(
        pickOwnBuild(
          rows: rows,
          triggeredAt: 1000000,
          historyFloor: 314,
          triggeredParameters: const {'S': 'a'},
          tryClaim: (_) => true,
        ),
        isNull,
      );
    });
  });
}
