import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

const _prefKey = 'app.locale_code';

/// 应用界面语言（与系统语言解耦，持久化在本地）。
class AppLocaleController extends Notifier<Locale> {
  late final SharedPreferences _prefs;

  @override
  Locale build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final raw = _prefs.getString(_prefKey);
    return switch (raw) {
      'en' => const Locale('en'),
      _ => const Locale('zh'),
    };
  }

  Future<void> setLocale(Locale locale) async {
    final code = locale.languageCode;
    if (code != 'zh' && code != 'en') return;
    state = Locale(code);
    await _prefs.setString(_prefKey, code);
  }
}

final appLocaleProvider = NotifierProvider<AppLocaleController, Locale>(
  AppLocaleController.new,
);
