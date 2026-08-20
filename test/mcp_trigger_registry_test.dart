import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:deployment/plug/mcp_server/application/mcp_trigger_registry.dart';
import 'package:flutter_test/flutter_test.dart';

JenkinsBuild _build(int number, int timestamp, {int? queueId}) =>
    JenkinsBuild.fromJson({
      'number': number,
      'timestamp': timestamp,
      'queueId': queueId ?? -1,
    });

QueueItem _item(int id, {bool cancelled = false}) =>
    QueueItem.fromJson({'id': id, 'cancelled': cancelled});

void main() {
  test('每次 open 都发一个不同的 triggerId（同一项目同一毫秒也不重复）', () {
    final registry = McpTriggerRegistry();
    final a = registry.open(
      accountId: 'acct',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {'SERVICE': 'admin-web'},
    );
    final b = registry.open(
      accountId: 'acct',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {'SERVICE': 'admin-api'},
    );
    expect(a.triggerId, isNotEmpty);
    expect(b.triggerId, isNotEmpty);
    expect(a.triggerId, isNot(b.triggerId));
    expect(registry.byId(a.triggerId), same(a));
    expect(registry.byId(b.triggerId), same(b));
    expect(registry.byId('trg_不存在'), isNull);
  });

  test('认领查询只算同项目的其它触发', () {
    final registry = McpTriggerRegistry();
    final first = registry.open(
      accountId: 'acct',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {},
    )
      ..queueId = 11
      ..buildNumber = 314;

    expect(registry.isBuildNumberClaimed('team/app', 314), isTrue);
    expect(registry.isQueueIdClaimed('team/app', 11), isTrue);
    // 自己不算占用自己
    expect(
      registry.isBuildNumberClaimed(
        'team/app',
        314,
        exceptTriggerId: first.triggerId,
      ),
      isFalse,
    );
    // 别的项目同号互不影响
    expect(registry.isBuildNumberClaimed('team/other', 314), isFalse);
  });

  test('容量上限淘汰最旧记录', () {
    final registry = McpTriggerRegistry(capacity: 2);
    final ids = [
      for (var i = 0; i < 3; i++)
        registry
            .open(
              accountId: 'acct',
              projectFullName: 'team/app',
              triggeredAt: 1000 + i,
              parameters: const {},
            )
            .triggerId,
    ];
    expect(registry.byId(ids[0]), isNull);
    expect(registry.byId(ids[1]), isNotNull);
    expect(registry.byId(ids[2]), isNotNull);
  });

  test('pickUnclaimedQueueItemId 按 id 升序取第一个未认领、未取消的排队项', () {
    final items = [_item(31), _item(30, cancelled: true), _item(32)];
    expect(pickUnclaimedQueueItemId(items, (_) => false), 31);
    expect(pickUnclaimedQueueItemId(items, (id) => id == 31), 32);
    expect(pickUnclaimedQueueItemId(items, (_) => true), isNull);
    expect(pickUnclaimedQueueItemId(const [], (_) => false), isNull);
  });

  group('pickTriggeredBuild', () {
    test('取触发后最早出现且未被认领的构建', () {
      final history = [
        _build(315, 1020000, queueId: 12),
        _build(314, 1010000, queueId: 11),
        // 触发前 100 秒的构建落在容差窗口外，不会被误认
        _build(313, 900000, queueId: 10),
      ];
      final picked = pickTriggeredBuild(history: history, triggeredAt: 1005000);
      expect(picked?.number, 314);
    });

    test('同一项目 30 秒内两次触发不会串到同一个构建号', () {
      // 第一次触发认领了 #314；第二次触发（18 秒后）即使落在 30 秒容差窗口里，
      // 也必须跳过 #314，只能拿 #315。这正是老实现串号的场景。
      final history = [
        _build(315, 1020000, queueId: 12),
        _build(314, 1002000, queueId: 11),
      ];
      final picked = pickTriggeredBuild(
        history: history,
        triggeredAt: 1020000,
        buildNumberClaimed: (n) => n == 314,
      );
      expect(picked?.number, 315);
      expect(picked?.queueId, 12);

      // 第二次触发的构建还没起来时宁可返回 null（调用方后续用 triggerId 复查），
      // 也不能把上一次的 #314 认成自己的。
      expect(
        pickTriggeredBuild(
          history: [_build(314, 1002000, queueId: 11)],
          triggeredAt: 1020000,
          buildNumberClaimed: (n) => n == 314,
        ),
        isNull,
      );
    });

    test('queueId 已被别的触发认领时同样跳过', () {
      final history = [_build(314, 1020000, queueId: 11)];
      expect(
        pickTriggeredBuild(
          history: history,
          triggeredAt: 1020000,
          queueIdClaimed: (id) => id == 11,
        ),
        isNull,
      );
    });

    test('触发时刻之前的构建一律不认', () {
      final history = [_build(313, 1000, queueId: 10)];
      expect(pickTriggeredBuild(history: history, triggeredAt: 100000), isNull);
    });
  });
}
