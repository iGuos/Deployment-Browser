import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build_parameter.dart';
import '../domain/jenkins_node.dart';
import 'jenkins_repository.dart';

/// [projectDetailProvider] 的 family 参数：账号 + Job fullName。
typedef ProjectDetailKey = ({String accountId, String fullName});

@immutable
class ProjectDetail {
  const ProjectDetail({
    required this.raw,
    required this.parameters,
    required this.subJobs,
    required this.isMultibranch,
    this.description,
    this.url,
  });

  final Map<String, dynamic> raw;
  final List<BuildParameter> parameters;
  final List<JenkinsNode> subJobs;
  final bool isMultibranch;
  final String? description;
  final String? url;
}

/// 拉取项目详情（参数定义、最近构建、子分支等）。
final projectDetailProvider =
    FutureProvider.family<ProjectDetail, ProjectDetailKey>((ref, key) async {
  final repo = ref.watch(jenkinsRepositoryForAccountProvider(key.accountId));
  if (repo == null) {
    throw Exception('Jenkins 未配置');
  }
  final detail = await repo.fetchJobDetail(key.fullName);
  final cls = ((detail.raw['_class'] as String?) ?? '').toLowerCase();
  final isMultibranch = cls.contains('multibranch');
  final subJobs = (detail.raw['jobs'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map((j) => JenkinsNode.fromJson(j, parentFullName: key.fullName))
          .where((n) => n.kind == JenkinsNodeKind.job)
          .toList() ??
      const <JenkinsNode>[];
  return ProjectDetail(
    raw: detail.raw,
    parameters: detail.parameters,
    subJobs: subJobs,
    isMultibranch: isMultibranch,
    description: detail.raw['description'] as String?,
    url: detail.raw['url'] as String?,
  );
});
