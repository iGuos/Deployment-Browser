import 'package:flutter/foundation.dart';

/// 标签类型。
enum WorkspaceTabKind { project, settings }

/// 标签状态：每个 tab 唯一 [id]，可指向项目或设置页。
@immutable
class WorkspaceTab {
  const WorkspaceTab({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.projectFullName,
    this.projectKind,
  });

  final String id;
  final WorkspaceTabKind kind;
  final String title;
  final String? subtitle;

  /// 仅 project 类型有效：完整 Job 路径（如 backend/order-service）
  final String? projectFullName;

  /// 仅 project 类型有效：'job' / 'multibranch'
  final String? projectKind;

  WorkspaceTab copyWith({
    String? title,
    String? subtitle,
  }) {
    return WorkspaceTab(
      id: id,
      kind: kind,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      projectFullName: projectFullName,
      projectKind: projectKind,
    );
  }

  static WorkspaceTab settings() => const WorkspaceTab(
        id: '__settings__',
        kind: WorkspaceTabKind.settings,
        title: 'Jenkins 配置',
      );

  static WorkspaceTab project({
    required String fullName,
    required String displayName,
    required bool multibranch,
  }) {
    return WorkspaceTab(
      id: 'job:$fullName',
      kind: WorkspaceTabKind.project,
      title: displayName,
      subtitle: fullName,
      projectFullName: fullName,
      projectKind: multibranch ? 'multibranch' : 'job',
    );
  }
}
