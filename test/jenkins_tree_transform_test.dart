import 'package:deployment/features/jenkins/domain/jenkins_node.dart';
import 'package:deployment/features/jenkins/domain/jenkins_tree_transform.dart';
import 'package:flutter_test/flutter_test.dart';

JenkinsNode _job(String name, {String? parent}) {
  final fn = parent == null || parent.isEmpty ? name : '$parent/$name';
  return JenkinsNode(
    name: name,
    fullName: fn,
    url: '',
    kind: JenkinsNodeKind.job,
    color: null,
    children: const [],
  );
}

JenkinsNode _folder(String name, List<JenkinsNode> children, {String? parent}) {
  final fn = parent == null || parent.isEmpty ? name : '$parent/$name';
  return JenkinsNode(
    name: name,
    fullName: fn,
    url: '',
    kind: JenkinsNodeKind.folder,
    color: null,
    children: children,
  );
}

void main() {
  test('flat collects jobs under folders and sorts by fullName', () {
    final roots = [
      _folder('b', [_job('j2', parent: 'b'), _job('j1', parent: 'b')]),
      _job('rootjob'),
    ];
    final flat = transformJenkinsSidebarTree(roots, JenkinsSidebarTreeMode.flat);
    expect(flat.map((e) => e.fullName).toList(), ['b/j1', 'b/j2', 'rootjob']);
  });

  test('hierarchical leaves tree unchanged', () {
    final roots = [_folder('x', [_job('y', parent: 'x')])];
    final h = transformJenkinsSidebarTree(roots, JenkinsSidebarTreeMode.hierarchical);
    expect(identical(h, roots), isTrue);
  });

  test('favorites preserves order and uses flat display names', () {
    final roots = [
      _folder('b', [_job('j2', parent: 'b'), _job('j1', parent: 'b')]),
      _job('rootjob'),
    ];
    final fav = transformJenkinsSidebarTree(
      roots,
      JenkinsSidebarTreeMode.favorites,
      orderedFavoriteFullNames: ['rootjob', 'b/j2', 'missing'],
    );
    expect(fav.map((e) => e.fullName).toList(), ['rootjob', 'b/j2']);
    expect(fav.map((e) => e.name).toList(), ['rootjob', 'b/j2']);
  });

  test('favorites empty list yields empty roots', () {
    final roots = [_job('a')];
    final fav = transformJenkinsSidebarTree(
      roots,
      JenkinsSidebarTreeMode.favorites,
      orderedFavoriteFullNames: [],
    );
    expect(fav, isEmpty);
  });
}
