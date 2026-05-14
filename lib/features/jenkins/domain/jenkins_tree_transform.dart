import 'jenkins_node.dart';

/// 侧栏项目树的展示方式（与 Jenkins API 返回的原始层级无关，仅为 UI 变换）。
enum JenkinsSidebarTreeMode {
  /// Jenkins 视图/文件夹等为可展开分组（与控制台「分组」一致），子项为工程列表。
  hierarchical,

  /// 所有可打开的 Job（含多分支流水线）单层列表，按全路径排序。
  flat,

  /// 仅展示已收藏的可打开 Job（顺序与收藏列表一致）。
  favorites,
}

/// 从 Jenkins 根列表收集所有可作为侧栏打开目标的节点（Job + 多分支父 Job）。
///
/// 遍历时跳过普通 Folder，多分支下的「分支」子 Job 不单独列出（在发版页内再选分支）。
List<JenkinsNode> collectSidebarProjectNodes(List<JenkinsNode> roots) {
  final out = <JenkinsNode>[];

  void walk(JenkinsNode n) {
    switch (n.kind) {
      case JenkinsNodeKind.folder:
        for (final c in n.children) {
          walk(c);
        }
        break;
      case JenkinsNodeKind.multibranch:
        out.add(n);
        break;
      case JenkinsNodeKind.job:
        out.add(n);
        break;
      case JenkinsNodeKind.unknown:
        if (n.children.isNotEmpty) {
          for (final c in n.children) {
            walk(c);
          }
        } else {
          out.add(n);
        }
        break;
    }
  }

  for (final r in roots) {
    walk(r);
  }
  out.sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
  return out;
}

/// 按当前模式变换树根列表。
///
/// [orderedFavoriteFullNames] 仅在 [JenkinsSidebarTreeMode.favorites] 时使用。
List<JenkinsNode> transformJenkinsSidebarTree(
  List<JenkinsNode> roots,
  JenkinsSidebarTreeMode mode, {
  List<String> orderedFavoriteFullNames = const [],
}) {
  switch (mode) {
    case JenkinsSidebarTreeMode.hierarchical:
      return roots;
    case JenkinsSidebarTreeMode.flat:
      return collectSidebarProjectNodes(roots).map(_flatDisplayCopy).toList();
    case JenkinsSidebarTreeMode.favorites:
      return collectFavoriteProjectNodes(roots, orderedFavoriteFullNames);
  }
}

/// 仅保留收藏中的可打开 Job，平铺展示，顺序与 [orderedFavoriteFullNames] 一致。
List<JenkinsNode> collectFavoriteProjectNodes(
  List<JenkinsNode> roots,
  List<String> orderedFavoriteFullNames,
) {
  if (orderedFavoriteFullNames.isEmpty) return [];
  final all = collectSidebarProjectNodes(roots);
  final byName = {for (final n in all) n.fullName: n};
  final out = <JenkinsNode>[];
  for (final name in orderedFavoriteFullNames) {
    final n = byName[name];
    if (n != null) out.add(_flatDisplayCopy(n));
  }
  return out;
}

/// 平铺下列显示完整路径，避免不同目录下同名列混淆。
JenkinsNode _flatDisplayCopy(JenkinsNode n) {
  return JenkinsNode(
    name: n.fullName,
    fullName: n.fullName,
    url: n.url,
    kind: n.kind,
    color: n.color,
    children: const [],
    buildable: n.buildable,
    lastBuildNumber: n.lastBuildNumber,
    lastBuildResult: n.lastBuildResult,
  );
}
