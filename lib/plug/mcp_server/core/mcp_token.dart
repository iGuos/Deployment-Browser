import 'package:flutter/foundation.dart';

/// 一个 MCP 访问令牌：调用方需在请求头 `Authorization: Bearer <secret>`
/// （或 `X-MCP-Token: <secret>`）中携带 [secret] 才能调用接口。
///
/// [allowedAccountIds] / [allowedProjectFullNames] 为空表示「不限制」（放行全部）；
/// 非空时仅允许访问列出的账号 / 项目。项目作用域以 Jenkins `fullName` 标识。
@immutable
class McpToken {
  const McpToken({
    required this.id,
    required this.label,
    required this.secret,
    this.allowedAccountIds = const [],
    this.allowedProjectFullNames = const [],
    this.createdAtMs = 0,
  });

  /// 本地唯一标识（仅用于持久化与 UI 索引，不参与鉴权）。
  final String id;

  /// 用户可见的备注名。
  final String label;

  /// 实际用于鉴权的明文令牌串。
  final String secret;

  /// 允许访问的账号 id 列表；空 = 全部账号。
  final List<String> allowedAccountIds;

  /// 允许访问的项目 fullName 列表；空 = 该 token 可见账号下的全部项目。
  final List<String> allowedProjectFullNames;

  final int createdAtMs;

  bool get scopesAllAccounts => allowedAccountIds.isEmpty;
  bool get scopesAllProjects => allowedProjectFullNames.isEmpty;

  bool allowsAccount(String accountId) =>
      allowedAccountIds.isEmpty || allowedAccountIds.contains(accountId);

  bool allowsProject(String projectFullName) =>
      allowedProjectFullNames.isEmpty ||
      allowedProjectFullNames.contains(projectFullName);

  McpToken copyWith({
    String? id,
    String? label,
    String? secret,
    List<String>? allowedAccountIds,
    List<String>? allowedProjectFullNames,
    int? createdAtMs,
  }) {
    return McpToken(
      id: id ?? this.id,
      label: label ?? this.label,
      secret: secret ?? this.secret,
      allowedAccountIds: allowedAccountIds ?? this.allowedAccountIds,
      allowedProjectFullNames:
          allowedProjectFullNames ?? this.allowedProjectFullNames,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'secret': secret,
        'accounts': allowedAccountIds,
        'projects': allowedProjectFullNames,
        'createdAt': createdAtMs,
      };

  factory McpToken.fromJson(Map<String, dynamic> json) {
    List<String> strList(Object? raw) => raw is List
        ? raw.map((e) => e.toString()).toList(growable: false)
        : const [];
    return McpToken(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      secret: (json['secret'] as String?) ?? '',
      allowedAccountIds: strList(json['accounts']),
      allowedProjectFullNames: strList(json['projects']),
      createdAtMs: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}
