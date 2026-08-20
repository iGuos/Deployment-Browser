import 'package:flutter/foundation.dart';

import 'jenkins_build.dart';

/// 「哪条 build 属于哪一次触发」的进程内台账。
///
/// 发版 UI 的每个 tab（owner = `RunHandle.runId`）与 MCP 的每次 trigger_build
/// （owner = triggerId）**共用同一份**，因此两个通道不会把同一条构建各自认成
/// 自己的。这取代了早先按「递增号段」预占构建号的做法：号段是位置分配，
/// 触发失败会留下空洞、外部构建插队会整体错位；认领是事实登记，只在真的
/// 附着到某条构建时才占用。
class BuildAttributionRegistry {
  /// job → 构建号 → ownerId
  final Map<String, Map<int, String>> _owners = <String, Map<int, String>>{};

  /// 同步原子认领。
  ///
  /// 未被占用（或本来就是自己的）→ 登记并返回 true；已属于别人 → 返回 false。
  /// 整段没有 await，Dart 事件循环里不可能被打断，因此两个几乎同时轮询的 tab
  /// 只有一个能拿到同一个构建号。
  ///
  /// 一个 owner 在同一 job 下只持有一个号：认领新号会释放它先前持有的。
  bool claim(String jobFullName, int buildNumber, String ownerId) {
    if (buildNumber <= 0 || ownerId.isEmpty) return false;
    final byNumber = _owners.putIfAbsent(jobFullName, () => <int, String>{});
    final holder = byNumber[buildNumber];
    if (holder != null && holder != ownerId) return false;
    byNumber.removeWhere((number, owner) => owner == ownerId);
    byNumber[buildNumber] = ownerId;
    return true;
  }

  /// 该构建号是否已被**别人**持有。
  bool isHeldByOther(String jobFullName, int buildNumber, String ownerId) {
    final holder = _owners[jobFullName]?[buildNumber];
    return holder != null && holder != ownerId;
  }

  /// 某个构建号当前的持有者；没有则 null。
  ///
  /// 用于反向对账：拿一条构建号问「这是谁发的」——发版 tab 的 runId 或 MCP 的
  /// triggerId。
  String? ownerOf(String jobFullName, int buildNumber) =>
      _owners[jobFullName]?[buildNumber];

  /// 某 owner 当前持有的构建号；没有则 null。
  int? numberOf(String jobFullName, String ownerId) {
    final byNumber = _owners[jobFullName];
    if (byNumber == null) return null;
    for (final e in byNumber.entries) {
      if (e.value == ownerId) return e.key;
    }
    return null;
  }

  /// 释放某 owner 的占用（tab 关闭、run 被丢弃、触发失败时调用）。
  void release(String jobFullName, String ownerId) {
    final byNumber = _owners[jobFullName];
    if (byNumber == null) return;
    byNumber.removeWhere((number, owner) => owner == ownerId);
    if (byNumber.isEmpty) _owners.remove(jobFullName);
  }

  @visibleForTesting
  void clear() => _owners.clear();
}

/// 构建的参数快照与本次触发的匹配程度。
enum ParameterMatch {
  /// 本次触发的每个参数都在快照里且取值一致。
  matched,

  /// 至少一个参数在快照里存在但取值不同 —— 肯定不是本次触发。
  mismatched,

  /// 快照缺失或缺少可比的键，无法判断（老构建 / 非参数化 Job / Jenkins 未回传）。
  unknown,
}

/// 判断某条构建的参数快照是否属于本次触发。
///
/// 用**子集**语义：只要求「我传的每个键值在快照里一致」，快照里多出来的键忽略。
/// Jenkins 会自行补默认值与隐藏参数，全等比对会把自己的构建判成别人的。
ParameterMatch matchBuildParameters({
  required Map<String, String> triggered,
  required Map<String, String> snapshot,
}) {
  if (triggered.isEmpty) return ParameterMatch.unknown;
  var compared = 0;
  for (final e in triggered.entries) {
    final actual = snapshot[e.key];
    if (actual == null) continue;
    if (actual != e.value) return ParameterMatch.mismatched;
    compared++;
  }
  return compared == 0 ? ParameterMatch.unknown : ParameterMatch.matched;
}

/// 在构建历史里挑出属于本次触发的那条构建。
///
/// 发版 UI 与 MCP 共用这一份判定，保证两条通道的口径完全一致。三重约束缺一不可：
///
/// - `number > historyFloor`：排除触发前就已存在的构建（事实下界，不会漂移）；
/// - 触发者比对：排除**明确由别人**触发的构建（[expectedUserId]）；
/// - 参数快照匹配：排除本次发版另一路参数、或参数不同的人工触发；
/// - [tryClaim] 原子认领：几乎同时轮询的多个触发，只有一个能拿到同一个号。
///
/// 参数「对得上」的候选优先于「无法判断」的；同级按构建号升序，先触发的先拿。
/// 一条都认不到时返回 null —— 宁可让调用方继续等，也不要认错。
JenkinsReleaseHistoryRow? pickOwnBuild({
  required List<JenkinsReleaseHistoryRow> rows,
  required int triggeredAt,
  required int historyFloor,
  required Map<String, String> triggeredParameters,
  required bool Function(int buildNumber) tryClaim,
  String? expectedUserId,
  int toleranceMs = 30 * 1000,
}) {
  final candidates =
      rows
          .where((r) => r.build.number > historyFloor)
          .where((r) => r.build.timestamp >= triggeredAt - toleranceMs)
          .where((r) => _triggeredByExpectedUser(r, expectedUserId))
          .map(
            (r) => (
              row: r,
              match: matchBuildParameters(
                triggered: triggeredParameters,
                snapshot: r.parameters,
              ),
            ),
          )
          .where((c) => c.match != ParameterMatch.mismatched)
          .toList()
        ..sort((a, b) {
          final byMatch = _matchRank(a.match).compareTo(_matchRank(b.match));
          if (byMatch != 0) return byMatch;
          return a.row.build.number.compareTo(b.row.build.number);
        });
  for (final c in candidates) {
    if (tryClaim(c.row.build.number)) return c.row;
  }
  return null;
}

int _matchRank(ParameterMatch m) => m == ParameterMatch.matched ? 0 : 1;

/// 该构建是否**没有被排除**在「本账号触发」之外。
///
/// 只在两边都拿得到登录名、且确实不同时才判否——`releasedByUserId` 解析不到
/// （非 UserIdCause、Jenkins 未回传）时一律放过，否则会把自己的构建判成别人的，
/// 换来永久假排队，比偶尔认错更糟。
bool _triggeredByExpectedUser(
  JenkinsReleaseHistoryRow row,
  String? expectedUserId,
) {
  final expected = expectedUserId?.trim();
  if (expected == null || expected.isEmpty) return true;
  final actual = row.releasedByUserId?.trim();
  if (actual == null || actual.isEmpty) return true;
  return actual.toLowerCase() == expected.toLowerCase();
}
