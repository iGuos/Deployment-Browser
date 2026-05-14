import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

/// 与 [ThemeModeController] 读写键一致；独立窗口等无 Riverpod 场景可据此同步主题。
const kAppThemeModePreferenceKey = 'app.theme_mode';

/// 全局主题模式：跟随系统 / 深色 / 浅色。
class ThemeModeController extends Notifier<ThemeMode> {
  late final SharedPreferences _prefs;

  @override
  ThemeMode build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final raw = _prefs.getString(kAppThemeModePreferenceKey);
    return switch (raw) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    await _prefs.setString(kAppThemeModePreferenceKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);
