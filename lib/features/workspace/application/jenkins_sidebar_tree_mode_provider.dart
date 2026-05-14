import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';
import '../../jenkins/domain/jenkins_tree_transform.dart';

const _kSidebarTreeMode = 'jenkins.sidebar.tree_layout_v1';

class JenkinsSidebarTreeModeNotifier extends Notifier<JenkinsSidebarTreeMode> {
  @override
  JenkinsSidebarTreeMode build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return _parse(prefs.getString(_kSidebarTreeMode));
  }

  static JenkinsSidebarTreeMode _parse(String? raw) {
    if (raw == null) return JenkinsSidebarTreeMode.hierarchical;
    // 旧版「按路径分组」已移除，偏好仍存 grouped 时回落到目录结构。
    if (raw == 'grouped') return JenkinsSidebarTreeMode.hierarchical;
    for (final v in JenkinsSidebarTreeMode.values) {
      if (v.name == raw) return v;
    }
    return JenkinsSidebarTreeMode.hierarchical;
  }

  void setMode(JenkinsSidebarTreeMode mode) {
    ref.read(sharedPreferencesProvider).setString(_kSidebarTreeMode, mode.name);
    state = mode;
  }
}

final jenkinsSidebarTreeModeProvider =
    NotifierProvider<JenkinsSidebarTreeModeNotifier, JenkinsSidebarTreeMode>(
  JenkinsSidebarTreeModeNotifier.new,
);
