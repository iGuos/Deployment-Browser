import 'package:flutter/foundation.dart';

/// 一次触发尝试的诊断记录。
///
/// `triggerBuild` 会按策略表逐个试（`buildWithParameters` 表单 / query、
/// Pipeline 的 `build` + `json=` 等），把每次的响应码记下来，才能回答
/// 「为什么这台 Jenkins 拿不到 `/queue/item/{id}/`」这类问题。
@immutable
class TriggerAttempt {
  const TriggerAttempt({
    required this.strategy,
    required this.endpoint,
    required this.statusCode,
    this.bodySnippet,
  });

  /// 策略编号，对应 `_postParameterizedTrigger` / `_postPlainTrigger` 的 switch。
  final int strategy;

  /// 命中的接口：`buildWithParameters` 或 `build`。
  final String endpoint;

  final int statusCode;

  /// 4xx 时 Jenkins 返回体的截断片段。**只用于本机日志排查**，
  /// 可能含 Jenkins 地址，绝不可回传给 MCP 调用方。
  final String? bodySnippet;

  @override
  String toString() =>
      's$strategy $endpoint HTTP $statusCode'
      '${bodySnippet == null || bodySnippet!.isEmpty ? '' : '：$bodySnippet'}';
}

/// 触发构建的结果：队列地址 + 命中的策略 + 全过程诊断。
@immutable
class TriggerResult {
  const TriggerResult({
    required this.location,
    required this.statusCode,
    required this.strategy,
    required this.endpoint,
    this.attempts = const [],
  });

  /// Jenkins 返回的 `Location` 头原文（可能是 `/queue/item/{id}/`，
  /// 也可能只是任务页 URL）。含 Jenkins 地址，不可外泄。
  final String location;

  final int statusCode;
  final int strategy;
  final String endpoint;

  /// 按时间顺序的所有尝试（含最终成功那次）。
  final List<TriggerAttempt> attempts;

  /// 是否拿到了可用于精确关联的队列项地址。
  bool get isQueueItemLocation => location.contains('/queue/item/');

  /// 去掉 scheme + host 的路径，可安全写入日志 / 回传调用方。
  String get locationPath {
    final uri = Uri.tryParse(location);
    if (uri == null) return location;
    final q = uri.hasQuery ? '?${uri.query}' : '';
    return uri.path.isEmpty ? location : '${uri.path}$q';
  }

  /// 失败尝试（4xx）的一行式摘要，供日志与异常信息使用。
  String get failureSummary => attempts
      .where((a) => a.statusCode >= 400)
      .map((a) => a.toString())
      .join('；');
}
