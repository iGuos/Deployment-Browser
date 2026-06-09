import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

const _prefKey = 'app.notifications_enabled';

/// 是否在构建结束时弹本地通知（默认开）。
class NotificationsEnabledController extends Notifier<bool> {
  late final SharedPreferences _prefs;

  @override
  bool build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getBool(_prefKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await _prefs.setBool(_prefKey, value);
  }
}

final notificationsEnabledProvider =
    NotifierProvider<NotificationsEnabledController, bool>(
  NotificationsEnabledController.new,
);
