import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/preferences.dart';

const _prefKey = 'app.stage_view_mode';

/// Pipeline 阶段展示形态：纵向列表 / 横向卡片流程图。
enum StageViewMode { list, cards }

/// 全局的阶段视图模式（持久化）。
class StageViewModeController extends Notifier<StageViewMode> {
  late final SharedPreferences _prefs;

  @override
  StageViewMode build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getString(_prefKey) == 'cards'
        ? StageViewMode.cards
        : StageViewMode.list;
  }

  Future<void> setMode(StageViewMode mode) async {
    state = mode;
    await _prefs.setString(_prefKey, mode.name);
  }

  Future<void> toggle() =>
      setMode(state == StageViewMode.list ? StageViewMode.cards : StageViewMode.list);
}

final stageViewModeProvider =
    NotifierProvider<StageViewModeController, StageViewMode>(
  StageViewModeController.new,
);
