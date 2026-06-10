import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';

/// 每个 Jenkins 账号下、按 Job 记录的「通知别名」。
///
/// 数据形态：`{ jobFullName: alias }`。Job 全名常常很长 / 杂乱（如带 dev 前缀、
/// 多级目录），用别名在「构建完成通知」里替代它更易读。空别名表示未设置。
class JobAliasNotifier extends Notifier<Map<String, String>> {
  JobAliasNotifier(this.accountId);

  final String accountId;

  static String storageKey(String accountId) =>
      'jenkins.job_aliases_v1_$accountId';

  @override
  Map<String, String> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(storageKey(accountId));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, String>{};
      decoded.forEach((job, alias) {
        if (job is String && alias is String && alias.trim().isNotEmpty) {
          result[job] = alias;
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  String? aliasOf(String jobFullName) => state[jobFullName];

  /// 设置别名；空白视为清除。
  Future<void> setAlias(String jobFullName, String alias) async {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) return clearAlias(jobFullName);
    if (state[jobFullName] == trimmed) return;
    final next = Map<String, String>.from(state)..[jobFullName] = trimmed;
    await _persist(next);
    state = next;
  }

  Future<void> clearAlias(String jobFullName) async {
    if (!state.containsKey(jobFullName)) return;
    final next = Map<String, String>.from(state)..remove(jobFullName);
    await _persist(next);
    state = next;
  }

  Future<void> _persist(Map<String, String> data) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (data.isEmpty) {
      await prefs.remove(storageKey(accountId));
    } else {
      await prefs.setString(storageKey(accountId), jsonEncode(data));
    }
  }
}

final jobAliasProvider =
    NotifierProvider.family<JobAliasNotifier, Map<String, String>, String>(
  JobAliasNotifier.new,
);
