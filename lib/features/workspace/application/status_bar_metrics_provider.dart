import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/preferences.dart';

const _prefKey = 'app.statusbar_metrics';

/// 状态栏可开关展示的快捷指标。
enum StatusMetric { connection, project, workspaces, tabs }

const Set<StatusMetric> _defaults = {
  StatusMetric.connection,
  StatusMetric.project,
  StatusMetric.tabs,
};

/// 状态栏指标显隐集合（持久化）。用户可在状态栏右侧的开关菜单里切换。
class StatusBarMetricsController extends Notifier<Set<StatusMetric>> {
  late final SharedPreferences _prefs;

  @override
  Set<StatusMetric> build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    final raw = _prefs.getStringList(_prefKey);
    if (raw == null) return _defaults;
    final set = <StatusMetric>{};
    for (final name in raw) {
      for (final m in StatusMetric.values) {
        if (m.name == name) set.add(m);
      }
    }
    return set;
  }

  Future<void> toggle(StatusMetric metric) async {
    final next = {...state};
    if (!next.add(metric)) next.remove(metric);
    state = next;
    await _prefs.setStringList(_prefKey, next.map((m) => m.name).toList());
  }

  bool isEnabled(StatusMetric metric) => state.contains(metric);
}

final statusBarMetricsProvider =
    NotifierProvider<StatusBarMetricsController, Set<StatusMetric>>(
  StatusBarMetricsController.new,
);
