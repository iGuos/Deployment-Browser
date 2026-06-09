import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preferences.dart';

const _prefKey = 'app.accent_color';

/// 可选的主题强调色预设（null 表示用主题内置默认蓝）。
const List<Color> kAccentColorPresets = [
  Color(0xFF4C8BF5), // 默认蓝
  Color(0xFF7C5CFC), // 紫
  Color(0xFF22B07D), // 绿
  Color(0xFFE0863B), // 橙
  Color(0xFFE5556E), // 红粉
  Color(0xFF2BB3C0), // 青
];

/// 用户自定义的主题强调色；为 null 时各主题用内置默认。
///
/// 以 ARGB int 持久化在本地（key=[_prefKey]）。
class AccentColorController extends Notifier<Color?> {
  late final SharedPreferences _prefs;

  @override
  Color? build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final raw = _prefs.getInt(_prefKey);
    if (raw == null) return null;
    return Color(raw);
  }

  Future<void> setAccent(Color? color) async {
    state = color;
    if (color == null) {
      await _prefs.remove(_prefKey);
    } else {
      await _prefs.setInt(_prefKey, color.toARGB32());
    }
  }
}

final accentColorProvider =
    NotifierProvider<AccentColorController, Color?>(AccentColorController.new);
