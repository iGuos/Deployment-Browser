import 'package:flutter/foundation.dart';

/// Jenkins 构建结果。
enum BuildResult {
  success,
  failure,
  unstable,
  aborted,
  notBuilt,
  running,
  unknown;

  static BuildResult fromString(String? raw, {bool building = false}) {
    if (building) return BuildResult.running;
    return switch (raw?.toUpperCase()) {
      'SUCCESS' => BuildResult.success,
      'FAILURE' => BuildResult.failure,
      'UNSTABLE' => BuildResult.unstable,
      'ABORTED' => BuildResult.aborted,
      'NOT_BUILT' => BuildResult.notBuilt,
      _ => BuildResult.unknown,
    };
  }
}

@immutable
class JenkinsBuild {
  const JenkinsBuild({
    required this.number,
    required this.url,
    required this.building,
    required this.timestamp,
    required this.duration,
    required this.estimatedDuration,
    this.result,
    this.displayName,
    this.fullDisplayName,
    this.queueId,
  });

  final int number;
  final String url;
  final bool building;
  final int timestamp;
  final int duration;
  final int estimatedDuration;
  final String? result;
  final String? displayName;
  final String? fullDisplayName;

  /// 触发本次构建的队列项 id（Jenkins `Run.queueId`）。
  ///
  /// 这是「一次触发」与「一条 build」之间唯一稳定的关联键：触发接口同步返回
  /// `/queue/item/{id}/`，队列项过期后仍可用它在构建历史里反查构建号。
  /// Jenkins 对老构建 / 未知来源返回 -1，这里统一归一化为 null。
  final int? queueId;

  BuildResult get resultEnum => BuildResult.fromString(result, building: building);

  /// 估算进度（0.0 – 1.0）。运行中且 estimatedDuration > 0 才有意义。
  double get progress {
    if (!building) return resultEnum == BuildResult.unknown ? 0.0 : 1.0;
    if (estimatedDuration <= 0) return 0.0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - timestamp;
    final ratio = elapsed / estimatedDuration;
    if (ratio.isNaN || ratio.isInfinite) return 0.0;
    return ratio.clamp(0.0, 0.98);
  }

  factory JenkinsBuild.fromJson(Map<String, dynamic> json) {
    return JenkinsBuild(
      number: (json['number'] as num?)?.toInt() ?? 0,
      url: (json['url'] as String?) ?? '',
      building: (json['building'] as bool?) ?? false,
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      estimatedDuration: (json['estimatedDuration'] as num?)?.toInt() ?? 0,
      result: json['result'] as String?,
      displayName: json['displayName'] as String?,
      fullDisplayName: json['fullDisplayName'] as String?,
      queueId: switch ((json['queueId'] as num?)?.toInt()) {
        final int id when id >= 0 => id,
        _ => null,
      },
    );
  }
}

/// 一条「发版 / 参数化构建」历史记录（构建元数据 + 当次参数快照）。
@immutable
class JenkinsReleaseHistoryRow {
  const JenkinsReleaseHistoryRow({
    required this.build,
    required this.parameters,
    this.releasedBy,
    this.releasedByUserId,
    this.gitRevision,
  });

  final JenkinsBuild build;

  /// 来自该次 build 的 `ParametersAction`；非参数化 Job 可能为空。
  final Map<String, String> parameters;

  /// 触发构建的用户（`UserIdCause` 等）；解析不到则为 null。展示用，可能是显示名。
  final String? releasedBy;

  /// 触发者的 Jenkins 登录名（`UserIdCause.userId`）；解析不到则为 null。
  ///
  /// 与账号配置里的 username 同一命名空间，因此可用来判断「这条构建是不是本
  /// 账号触发的」——[releasedBy] 常是显示名，不能拿来做这种比较。
  final String? releasedByUserId;

  /// 本次构建对应的 Git 提交 SHA（完整）；展示时可缩写。
  final String? gitRevision;
}

/// 构建阶段（Pipeline `wfapi/describe` 接口的简化形式）
@immutable
class BuildStage {
  const BuildStage({
    required this.id,
    required this.name,
    required this.status,
    required this.durationMillis,
    this.startTimeMillis,
  });

  final String id;
  final String name;

  /// IN_PROGRESS / SUCCESS / FAILED / ABORTED / NOT_EXECUTED / PAUSED_PENDING_INPUT
  final String status;

  final int durationMillis;
  final int? startTimeMillis;

  bool get isRunning => status.toUpperCase() == 'IN_PROGRESS';
  bool get isSuccess => status.toUpperCase() == 'SUCCESS';
  bool get isFailed => status.toUpperCase() == 'FAILED' || status.toUpperCase() == 'ABORTED';
  bool get isPending => !isRunning && !isSuccess && !isFailed;

  factory BuildStage.fromJson(Map<String, dynamic> json) {
    return BuildStage(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'UNKNOWN',
      durationMillis: (json['durationMillis'] as num?)?.toInt() ?? 0,
      startTimeMillis: (json['startTimeMillis'] as num?)?.toInt(),
    );
  }
}

/// 运行中构建的阶段展示：用上一跑 [template] 固定「全部阶段」顺序与名称，
/// 用当前 [live]（`wfapi/describe` 增量结果）覆盖已出现的阶段；尚未出现的为
/// `NOT_EXECUTED`，便于 UI 一次列出全部行再随进度逐段变绿。
///
/// [template] 为空时直接返回 [live]（首次构建 / 无上一跑数据时的退化）。
List<BuildStage> mergeBuildStagesForRunning(
  List<BuildStage> template,
  List<BuildStage> live,
) {
  if (template.isEmpty) return live;
  if (live.isEmpty) {
    return [
      for (final t in template)
        BuildStage(
          id: t.id,
          name: t.name,
          status: 'NOT_EXECUTED',
          durationMillis: 0,
          startTimeMillis: null,
        ),
    ];
  }
  final liveByName = <String, BuildStage>{};
  for (final s in live) {
    liveByName.putIfAbsent(s.name, () => s);
  }
  final usedNames = <String>{};
  final out = <BuildStage>[];
  for (final t in template) {
    final s = liveByName[t.name];
    if (s != null) {
      out.add(s);
      usedNames.add(t.name);
    } else {
      out.add(
        BuildStage(
          id: t.id,
          name: t.name,
          status: 'NOT_EXECUTED',
          durationMillis: 0,
          startTimeMillis: null,
        ),
      );
    }
  }
  for (final s in live) {
    if (!usedNames.contains(s.name)) {
      out.add(s);
      usedNames.add(s.name);
    }
  }
  return out;
}

/// 队列项（POST /build 后的 Location 头返回此 URL）。
@immutable
class QueueItem {
  const QueueItem({
    required this.id,
    required this.cancelled,
    required this.executable,
    this.why,
    this.parameters = const {},
  });

  final int id;
  final bool cancelled;

  /// 一旦排队完成，executable 会包含一个 build 引用，含 number 与 url
  final ({int number, String url})? executable;

  final String? why;

  /// 排队项自带的参数（Jenkins `params` 字段）。
  ///
  /// 队列还没出队时构建号尚不存在，这是**唯一**能判断「这个排队项是不是我这次
  /// 触发建立的」的依据 —— 触发响应没给出 `/queue/item/{id}/` 时全靠它。
  final Map<String, String> parameters;

  bool get isWaiting => executable == null && !cancelled;
  bool get isStarted => executable != null;

  factory QueueItem.fromJson(Map<String, dynamic> json) {
    final exec = json['executable'];
    return QueueItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      cancelled: (json['cancelled'] as bool?) ?? false,
      why: json['why'] as String?,
      parameters: parseQueueItemParams(json['params']),
      executable: exec is Map<String, dynamic>
          ? (
              number: (exec['number'] as num?)?.toInt() ?? 0,
              url: (exec['url'] as String?) ?? '',
            )
          : null,
    );
  }
}

/// 解析队列项的 `params` 字段。
///
/// Jenkins 给的是一整个字符串，形如 `"\nSERVICE=admin-api\nGIT_BRANCH=main"`；
/// 值里可能带 `=`，所以只按**第一个** `=` 切分。
Map<String, String> parseQueueItemParams(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return const {};
  final out = <String, String>{};
  for (final line in raw.split('\n')) {
    final text = line.trim();
    if (text.isEmpty) continue;
    final i = text.indexOf('=');
    if (i <= 0) continue;
    out[text.substring(0, i).trim()] = text.substring(i + 1).trim();
  }
  return out;
}
