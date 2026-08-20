import '../../../features/jenkins/domain/jenkins_build.dart';

/// 一次 `trigger_build` 调用的本地台账。
///
/// Jenkins 的 queueId 并不总能拿到：部分实例对 Pipeline 的 `POST /build` + `json=`
/// 只 302 回任务页，反向代理也可能改写 `Location`，那时 `/queue/item/{id}/`
/// 无从解析。但调用方**必须**有一个能区分「同一项目的第 N 次触发」的键，
/// 所以每次触发都额外生成本地唯一的 [triggerId]，再把后续查到的
/// queueId / 构建号回填进来。
class McpTriggerRecord {
  McpTriggerRecord({
    required this.triggerId,
    required this.accountId,
    required this.attributionKey,
    required this.accountUserId,
    required this.projectFullName,
    required this.triggeredAt,
    required this.parameters,
    required this.historyFloor,
  });

  /// 本次触发的唯一键，永不为 null，跨并发触发也互不相同。
  final String triggerId;

  /// 对外账号 id（已哈希，不含任何明文）。
  final String accountId;

  /// 共享构建归属台账（[BuildAttributionRegistry]）的键，与发版 UI 同一口径。
  final String attributionKey;

  /// 触发所用账号的 Jenkins 登录名；用于排除别人手动触发的构建。
  final String? accountUserId;

  final String projectFullName;
  final int triggeredAt;
  final Map<String, String> parameters;

  /// 触发前 Jenkins 上该 Job 的最大构建号；本次构建号必然大于它。
  final int historyFloor;

  /// Jenkins 队列项 id；解析不到 `Location` 时可能稍后才认领到。
  int? queueId;

  /// queueId 的来源，便于排查为什么某些 Jenkins 拿不到队列项：
  /// `location`（触发响应头）/ `queue-scan`（扫队列认领）/ `history`（历史反查）。
  String? queueIdSource;
  int? buildNumber;
  bool cancelled = false;
}

/// 进程内的触发台账：发号 + 记录「哪个 queueId / 构建号已属于哪次触发」。
///
/// 认领信息是同一项目连续多次发版不串号的依据：兜底逻辑挑构建时，必须跳过
/// 已被别的触发认领过的构建号。
class McpTriggerRegistry {
  McpTriggerRegistry({this.capacity = 300});

  /// 最多保留多少条触发记录（超出后丢弃最旧的）。
  final int capacity;

  /// 插入顺序即触发顺序，_prune 依赖这一点。
  final Map<String, McpTriggerRecord> _records = <String, McpTriggerRecord>{};
  int _seq = 0;

  McpTriggerRecord open({
    required String accountId,
    required String attributionKey,
    required String projectFullName,
    String? accountUserId,
    required int triggeredAt,
    required Map<String, String> parameters,
    int historyFloor = 0,
  }) {
    final record = McpTriggerRecord(
      triggerId: 'trg_${triggeredAt}_${++_seq}',
      accountId: accountId,
      attributionKey: attributionKey,
      accountUserId: accountUserId,
      projectFullName: projectFullName,
      triggeredAt: triggeredAt,
      parameters: Map<String, String>.unmodifiable(parameters),
      historyFloor: historyFloor,
    );
    _records[record.triggerId] = record;
    while (_records.length > capacity) {
      _records.remove(_records.keys.first);
    }
    return record;
  }

  McpTriggerRecord? byId(String? triggerId) =>
      (triggerId == null || triggerId.isEmpty) ? null : _records[triggerId];

  /// 该 queueId 是否已被本项目**其它**触发认领。
  bool isQueueIdClaimed(
    String projectFullName,
    int queueId, {
    String? exceptTriggerId,
  }) =>
      _records.values.any((r) =>
          r.triggerId != exceptTriggerId &&
          r.projectFullName == projectFullName &&
          r.queueId == queueId);
}

/// 从队列里挑一个属于本次触发的排队项：按 id 升序取第一个未取消、未被别人认领的。
///
/// 队列是 FIFO，升序取用能让「先触发的先认领」，并发触发同一项目也不会互抢。
int? pickUnclaimedQueueItemId(
  List<QueueItem> items,
  bool Function(int id) claimed,
) {
  final sorted = items.where((i) => i.id > 0 && !i.cancelled).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final item in sorted) {
    if (!claimed(item.id)) return item.id;
  }
  return null;
}
