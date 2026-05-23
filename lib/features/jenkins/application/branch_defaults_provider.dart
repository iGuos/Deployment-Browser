import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';

/// 每个 Jenkins 账号下、按 (Job, 参数名) 记录的"用户偏好默认分支"。
///
/// 数据形态：`{ jobFullName: { paramName: branchValue } }`。
/// 同一账号下不同 Job 互不影响；切换账号会拉到各自的偏好。
class BranchDefaultsNotifier
    extends Notifier<Map<String, Map<String, String>>> {
  BranchDefaultsNotifier(this.accountId);

  final String accountId;

  static String storageKey(String accountId) =>
      'jenkins.branch_defaults_v1_$accountId';

  @override
  Map<String, Map<String, String>> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(storageKey(accountId));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, String>>{};
      decoded.forEach((job, params) {
        if (job is String && params is Map) {
          final paramMap = <String, String>{};
          params.forEach((k, v) {
            if (k is String && v is String && v.isNotEmpty) paramMap[k] = v;
          });
          if (paramMap.isNotEmpty) result[job] = paramMap;
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  String? getDefault(String jobFullName, String paramName) =>
      state[jobFullName]?[paramName];

  Future<void> setDefault(
    String jobFullName,
    String paramName,
    String value,
  ) async {
    if (value.isEmpty) {
      return clearDefault(jobFullName, paramName);
    }
    final next = _deepCopy(state);
    final paramMap = next[jobFullName] ?? <String, String>{};
    paramMap[paramName] = value;
    next[jobFullName] = paramMap;
    await _persist(next);
    state = next;
  }

  Future<void> clearDefault(String jobFullName, String paramName) async {
    final existing = state[jobFullName];
    if (existing == null || !existing.containsKey(paramName)) return;
    final next = _deepCopy(state);
    final paramMap = next[jobFullName]!;
    paramMap.remove(paramName);
    if (paramMap.isEmpty) {
      next.remove(jobFullName);
    }
    await _persist(next);
    state = next;
  }

  Map<String, Map<String, String>> _deepCopy(
    Map<String, Map<String, String>> src,
  ) {
    final out = <String, Map<String, String>>{};
    src.forEach((k, v) {
      out[k] = Map<String, String>.from(v);
    });
    return out;
  }

  Future<void> _persist(Map<String, Map<String, String>> data) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (data.isEmpty) {
      await prefs.remove(storageKey(accountId));
    } else {
      await prefs.setString(storageKey(accountId), jsonEncode(data));
    }
  }
}

final branchDefaultsProvider = NotifierProvider.family<
  BranchDefaultsNotifier,
  Map<String, Map<String, String>>,
  String
>(BranchDefaultsNotifier.new);
