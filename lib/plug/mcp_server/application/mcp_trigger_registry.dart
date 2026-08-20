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
    required this.projectFullName,
    required this.triggeredAt,
    required this.parameters,
  });

  /// 本次触发的唯一键，永不为 null，跨并发触发也互不相同。
  final String triggerId;

  /// 对外账号 id（已哈希，不含任何明文）。
  final String accountId;
  final String projectFullName;
  final int triggeredAt;
  final Map<String, String> parameters;

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
    required String projectFullName,
    required int triggeredAt,
    required Map<String, String> parameters,
  }) {
    final record = McpTriggerRecord(
      triggerId: 'trg_${triggeredAt}_${++_seq}',
      accountId: accountId,
      projectFullName: projectFullName,
      triggeredAt: triggeredAt,
      parameters: Map<String, String>.unmodifiable(parameters),
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

  /// 该构建号是否已被本项目**其它**触发认领。
  bool isBuildNumberClaimed(
    String projectFullName,
    int buildNumber, {
    String? exceptTriggerId,
  }) =>
      _records.values.any((r) =>
          r.triggerId != exceptTriggerId &&
          r.projectFullName == projectFullName &&
          r.buildNumber == buildNumber);
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

/// 连 queueId 都拿不到时的兜底：在构建历史里挑一条属于本次触发的构建。
///
/// 只看触发时刻之后（留 [toleranceMs] 容忍设备与 Jenkins 的时钟偏差）出现、
/// 且 queueId 与构建号都没被别的触发认领过的构建，取其中最小的构建号。
/// 「排除已认领」是关键：仅按时间窗取最小号时，同一项目在容差内触发两次会把
/// 两次都指到同一个构建号。
JenkinsBuild? pickTriggeredBuild({
  required List<JenkinsBuild> history,
  required int triggeredAt,
  bool Function(int queueId)? queueIdClaimed,
  bool Function(int buildNumber)? buildNumberClaimed,
  int toleranceMs = 30 * 1000,
}) {
  final candidates = history.where((b) {
    if (b.number <= 0) return false;
    if (b.timestamp < triggeredAt - toleranceMs) return false;
    final q = b.queueId;
    if (q != null && (queueIdClaimed?.call(q) ?? false)) return false;
    if (buildNumberClaimed?.call(b.number) ?? false) return false;
    return true;
  }).toList()
    ..sort((a, b) => a.number.compareTo(b.number));
  return candidates.isEmpty ? null : candidates.first;
}
