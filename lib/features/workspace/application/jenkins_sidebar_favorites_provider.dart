import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';

/// 当前 Jenkins 账号下侧栏「收藏」的项目 fullName 列表（顺序即展示顺序）。
class JenkinsSidebarFavoritesNotifier extends Notifier<List<String>> {
  JenkinsSidebarFavoritesNotifier(this.accountId);

  final String accountId;

  static String storageKey(String accountId) => 'jenkins.sidebar.favorites_v1_$accountId';

  @override
  List<String> build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return List<String>.from(prefs.getStringList(storageKey(accountId)) ?? []);
  }

  Future<void> toggle(String fullName) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final next = List<String>.from(state);
    if (next.contains(fullName)) {
      next.remove(fullName);
    } else {
      next.add(fullName);
    }
    await prefs.setStringList(storageKey(accountId), next);
    state = next;
  }

  /// 按 fullName 移动收藏项；移动到 [beforeFullName] 之前，传 null 表示移到末尾。
  ///
  /// 之所以用 fullName 而不是 index：state 是持久化的全量收藏，可能含 Jenkins 已删除
  /// 的失效项；UI 渲染时这些项被过滤掉，可见列表的下标对不上 state 的下标。
  /// 用 fullName 索引可以正确处理含失效项的场景，缺失/不存在会优雅降级。
  Future<void> reorderByFullName(
    String fromFullName, {
    required String? beforeFullName,
  }) async {
    final list = List<String>.from(state);
    final fromIdx = list.indexOf(fromFullName);
    if (fromIdx < 0) return;

    final int targetIdx;
    if (beforeFullName == null) {
      targetIdx = list.length;
    } else {
      final idx = list.indexOf(beforeFullName);
      targetIdx = idx < 0 ? list.length : idx;
    }

    // 删除后插入：若插入点在原位置之后，需要 -1 抵消位移。
    final adjusted = targetIdx > fromIdx ? targetIdx - 1 : targetIdx;
    if (adjusted == fromIdx) return; // state 层面也无变化

    final moved = list.removeAt(fromIdx);
    list.insert(adjusted, moved);

    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(storageKey(accountId), list);
    state = list;
  }
}

final jenkinsSidebarFavoritesProvider =
    NotifierProvider.family<JenkinsSidebarFavoritesNotifier, List<String>, String>(
  JenkinsSidebarFavoritesNotifier.new,
);
