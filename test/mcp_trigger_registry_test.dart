import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:deployment/plug/mcp_server/application/mcp_trigger_registry.dart';
import 'package:flutter_test/flutter_test.dart';

QueueItem _item(
  int id, {
  bool cancelled = false,
  String? params,
}) => QueueItem.fromJson({
  'id': id,
  'cancelled': cancelled,
  'params': ?params,
});

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

  test('parseQueueItemParams 解析 Jenkins 的 params 串（值里带 = 也不切错）', () {
    expect(
      parseQueueItemParams('\nSERVICE=admin-api\nGIT_BRANCH=feat/a=b'),
      {'SERVICE': 'admin-api', 'GIT_BRANCH': 'feat/a=b'},
    );
    expect(parseQueueItemParams(null), isEmpty);
    expect(parseQueueItemParams('  '), isEmpty);
  });

  group('pickOwnQueueItemId', () {
    test('参数对得上的优先，不看 id 顺序——真并发也不会张冠李戴', () {
      // 队列里同时有别人（或本次发版另一路）的排队项，且 id 更小
      final items = [
        _item(30, params: '\nSERVICE=admin-web'),
        _item(31, params: '\nSERVICE=admin-api'),
      ];
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'admin-api'}, (_) => false),
        31,
      );
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'admin-web'}, (_) => false),
        30,
      );
    });

    test('参数明确不同的一律排除，挑不出就返回 null', () {
      final items = [_item(30, params: '\nSERVICE=admin-web')];
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'admin-api'}, (_) => false),
        isNull,
      );
    });

    test('已被别的触发认领的跳过', () {
      final items = [
        _item(30, params: '\nSERVICE=x'),
        _item(31, params: '\nSERVICE=x'),
      ];
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'x'}, (id) => id == 30),
        31,
      );
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'x'}, (_) => true),
        isNull,
      );
    });

    test('Jenkins 未回传 params 时按 id 升序兜底，取消的不算', () {
      final items = [_item(31), _item(30, cancelled: true), _item(32)];
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'x'}, (_) => false),
        31,
      );
      expect(pickOwnQueueItemId(const [], const {}, (_) => false), isNull);
    });

    test('有参数对得上的时候，不会退而取无法判断的那条', () {
      final items = [
        _item(30), // 无 params，id 更小
        _item(31, params: '\nSERVICE=admin-api'),
      ];
      expect(
        pickOwnQueueItemId(items, const {'SERVICE': 'admin-api'}, (_) => false),
        31,
      );
    });
  });
}
