import 'package:flutter/foundation.dart';

/// Jenkins 节点的种类。
///
/// - [folder]：包含子节点的容器（org folder / cloudbees folder）
/// - [multibranch]：多分支流水线（其内部的子 job 即「分支」）
/// - [job]：传统的 Job（Freestyle / Pipeline 等）
/// - [unknown]：未知类型（保底兜底）
enum JenkinsNodeKind { folder, multibranch, job, unknown }

/// 通用的 Jenkins 节点（Folder / Job / MultiBranch）。
///
/// `_class` 字段用于区分类型；本应用按下面的简单映射归类：
/// - 含 `Folder` / `OrganizationFolder` → folder
/// - 含 `WorkflowMultiBranchProject` → multibranch
/// - 其它含 `Project` / `Workflow` 的 job → job
@immutable
class JenkinsNode {
  const JenkinsNode({
    required this.name,
    required this.fullName,
    required this.url,
    required this.kind,
    required this.color,
    this.children = const [],
    this.buildable = false,
    this.lastBuildNumber,
    this.lastBuildResult,
  });

  /// 显示名（最末段）
  final String name;

  /// 完整路径名，例如 `backend/order-service`
  final String fullName;

  /// Jenkins 完整 URL
  final String url;

  final JenkinsNodeKind kind;

  /// Jenkins 节点的 `color` 字段（如 `blue`、`red`、`disabled`、`notbuilt`）
  final String? color;

  final List<JenkinsNode> children;

  /// 是否可触发构建（`/buildWithParameters` 或 `/build`）
  final bool buildable;

  final int? lastBuildNumber;

  /// 上一次构建结果：SUCCESS / FAILURE / ABORTED / UNSTABLE / null
  final String? lastBuildResult;

  bool get isFolder => kind == JenkinsNodeKind.folder || kind == JenkinsNodeKind.multibranch;

  bool get isLeaf => kind == JenkinsNodeKind.job;

  /// 侧栏是否可对该项目显示收藏星标（排除纯文件夹容器）。
  bool get canFavoriteInSidebar =>
      kind == JenkinsNodeKind.job ||
      kind == JenkinsNodeKind.multibranch ||
      kind == JenkinsNodeKind.unknown;

  JenkinsNode copyWith({
    List<JenkinsNode>? children,
    bool? buildable,
    int? lastBuildNumber,
    String? lastBuildResult,
  }) {
    return JenkinsNode(
      name: name,
      fullName: fullName,
      url: url,
      kind: kind,
      color: color,
      children: children ?? this.children,
      buildable: buildable ?? this.buildable,
      lastBuildNumber: lastBuildNumber ?? this.lastBuildNumber,
      lastBuildResult: lastBuildResult ?? this.lastBuildResult,
    );
  }

  factory JenkinsNode.fromJson(Map<String, dynamic> json, {String? parentFullName}) {
    final cls = (json['_class'] as String?) ?? '';
    final name = (json['name'] as String?) ?? '';
    final explicit = json['fullName'] as String?;
    final fullName = (explicit != null && explicit.isNotEmpty)
        ? explicit
        : (parentFullName == null || parentFullName.isEmpty
            ? name
            : '$parentFullName/$name');
    final children = (json['jobs'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((j) => JenkinsNode.fromJson(j, parentFullName: fullName))
            .toList() ??
        const [];
    return JenkinsNode(
      name: name,
      fullName: fullName,
      url: (json['url'] as String?) ?? '',
      kind: _kindFromClass(cls),
      color: json['color'] as String?,
      children: children,
      buildable: (json['buildable'] as bool?) ?? false,
      lastBuildNumber: (json['lastBuild'] is Map)
          ? (json['lastBuild']['number'] as int?)
          : null,
      lastBuildResult: (json['lastCompletedBuild'] is Map)
          ? (json['lastCompletedBuild']['result'] as String?)
          : null,
    );
  }

  static JenkinsNodeKind _kindFromClass(String cls) {
    final lower = cls.toLowerCase();
    if (lower.contains('multibranch')) return JenkinsNodeKind.multibranch;
    if (lower.contains('folder')) return JenkinsNodeKind.folder;
    if (lower.contains('workflowjob') ||
        lower.contains('freestyleproject') ||
        lower.contains('project') ||
        lower.contains('workflow')) {
      return JenkinsNodeKind.job;
    }
    return JenkinsNodeKind.unknown;
  }
}
