import 'package:flutter/foundation.dart';

import 'jenkins_config.dart';

/// 一个具名的 Jenkins 账号 = [config] 自身 + 用户可见的 [name] + 唯一 [id]。
///
/// `id` 仅用于本地持久化（账号列表索引、secure storage key）；
/// `name` 是 UI 上展示的标签，可以重命名。
@immutable
class JenkinsAccount {
  const JenkinsAccount({
    required this.id,
    required this.name,
    required this.config,
  });

  final String id;
  final String name;
  final JenkinsConfig config;

  /// 显示用的"短名"：name 非空则用 name，否则回落到 host。
  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final host = config.displayHost;
    return host.isNotEmpty ? host : id;
  }

  /// 副标题：始终展示主机名（即便 name 已经是主机名也无伤大雅）。
  String get subtitle => config.displayHost;

  JenkinsAccount copyWith({
    String? id,
    String? name,
    JenkinsConfig? config,
  }) {
    return JenkinsAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      config: config ?? this.config,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JenkinsAccount &&
          other.id == id &&
          other.name == name &&
          other.config == config);

  @override
  int get hashCode => Object.hash(id, name, config);
}
