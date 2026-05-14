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
}

final jenkinsSidebarFavoritesProvider =
    NotifierProvider.family<JenkinsSidebarFavoritesNotifier, List<String>, String>(
  JenkinsSidebarFavoritesNotifier.new,
);
