import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:deployment/plug/mcp_server/application/mcp_trigger_registry.dart';
import 'package:flutter_test/flutter_test.dart';

QueueItem _item(int id, {bool cancelled = false}) =>
    QueueItem.fromJson({'id': id, 'cancelled': cancelled});

void main() {
  test('每次 open 都发一个不同的 triggerId（同一项目同一毫秒也不重复）', () {
    final registry = McpTriggerRegistry();
    final a = registry.open(
      accountId: 'acct',
      attributionKey: 'acct::team/app',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {'SERVICE': 'admin-web'},
      historyFloor: 314,
    );
    final b = registry.open(
      accountId: 'acct',
      attributionKey: 'acct::team/app',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {'SERVICE': 'admin-api'},
      historyFloor: 314,
    );
    expect(a.triggerId, isNotEmpty);
    expect(b.triggerId, isNotEmpty);
    expect(a.triggerId, isNot(b.triggerId));
    expect(registry.byId(a.triggerId), same(a));
    expect(registry.byId(b.triggerId), same(b));
    expect(registry.byId('trg_不存在'), isNull);
  });

  test('容量上限淘汰最旧记录', () {
    final registry = McpTriggerRegistry(capacity: 2);
    final ids = [
      for (var i = 0; i < 3; i++)
        registry
            .open(
              accountId: 'acct',
              attributionKey: 'acct::team/app',
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

  test('queueId 认领只算同项目的其它触发', () {
    final registry = McpTriggerRegistry();
    final first = registry.open(
      accountId: 'acct',
      attributionKey: 'acct::team/app',
      projectFullName: 'team/app',
      triggeredAt: 1000,
      parameters: const {},
    )..queueId = 812;

    expect(registry.isQueueIdClaimed('team/app', 812), isTrue);
    expect(
      registry.isQueueIdClaimed(
        'team/app',
        812,
        exceptTriggerId: first.triggerId,
      ),
      isFalse,
    );
    expect(registry.isQueueIdClaimed('team/other', 812), isFalse);
  });

  test('pickUnclaimedQueueItemId 按 id 升序取第一个未认领、未取消的排队项', () {
    final items = [_item(31), _item(30, cancelled: true), _item(32)];
    expect(pickUnclaimedQueueItemId(items, (_) => false), 31);
    expect(pickUnclaimedQueueItemId(items, (id) => id == 31), 32);
    expect(pickUnclaimedQueueItemId(items, (_) => true), isNull);
    expect(pickUnclaimedQueueItemId(const [], (_) => false), isNull);
  });
}
