import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用启动时初始化一次的 SharedPreferences。
///
/// 在 main() 中通过 `overrideWithValue` 注入实际实例。
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider 必须在 main() 中通过 overrideWithValue 注入',
  );
});
