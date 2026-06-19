import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/jenkins/data/jenkins_repository.dart';
import '../../../features/jenkins/domain/build_parameter.dart';
import '../../../features/jenkins/domain/jenkins_build.dart';
import '../../../features/jenkins/domain/jenkins_node.dart';
import '../../../features/jenkins/domain/jenkins_tree_transform.dart';
import '../../../features/settings/data/jenkins_accounts_repository.dart';
import '../core/mcp_protocol.dart';
import '../core/mcp_token.dart';
import '../core/mcp_tool_specs.dart';
import 'mcp_server_state_provider.dart';

/// 把 MCP 工具调用翻译为对既有 Jenkins 仓储 / Provider 的读取，
/// 并按调用令牌的作用域（允许的账号 / 项目）做访问控制。
class McpJenkinsService {
  McpJenkinsService(this._ref);

  final Ref _ref;

  Future<McpCallOutcome> dispatch({
    required String tokenId,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    final token = _ref.read(mcpServerConfigProvider).tokenById(tokenId);
    if (token == null) {
      return const McpCallOutcome.error('访问令牌已失效，请重新配置。');
    }
    try {
      switch (toolName) {
        case kToolListAccounts:
          return await _listAccounts(token);
        case kToolListProjects:
          return await _listProjects(token, arguments);
        case kToolGetProjectParameters:
          return await _getProjectParameters(token, arguments);
        case kToolTriggerBuild:
          return await _triggerBuild(token, arguments);
        case kToolGetBuildStatus:
          return await _getBuildStatus(token, arguments);
        case kToolGetReleaseHistory:
          return await _getReleaseHistory(token, arguments);
        default:
          return McpCallOutcome.error('未知工具：$toolName');
      }
    } catch (e) {
      return McpCallOutcome.error('调用失败：$e');
    }
  }

  // ---------------- 工具实现 ----------------

  Future<McpCallOutcome> _listAccounts(McpToken token) async {
    final state = await _ref.read(jenkinsAccountsProvider.future);
    final accounts = state.accounts
        .where((a) => token.allowsAccount(a.id))
        .map((a) => {
              'id': a.id,
              'name': a.displayName,
              'host': a.config.displayHost,
              'baseUrl': a.config.baseUrl,
              'active': a.id == state.activeId,
              'configured': a.config.isComplete,
            })
        .toList(growable: false);
    return McpCallOutcome.ok({'accounts': accounts});
  }

  Future<McpCallOutcome> _listProjects(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final accountId = _str(args['accountId']);
    final guard = _guardAccount(token, accountId);
    if (guard != null) return guard;

    final roots = await _ref.read(
      jenkinsTreeForAccountProvider(accountId).future,
    );
    final projects = collectSidebarProjectNodes(roots)
        .where((n) => token.allowsProject(n.fullName))
        .map(_projectJson)
        .toList(growable: false);
    return McpCallOutcome.ok({
      'accountId': accountId,
      'projects': projects,
    });
  }

  Future<McpCallOutcome> _getProjectParameters(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final accountId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final guard = _guardProject(token, accountId, fullName);
    if (guard != null) return guard;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(accountId));
    if (repo == null) return _accountUnavailable(accountId);

    final detail = await repo.fetchJobDetail(fullName);
    return McpCallOutcome.ok({
      'accountId': accountId,
      'projectFullName': fullName,
      'jobClass': detail.raw['_class'],
      'parameters':
          detail.parameters.map(_parameterJson).toList(growable: false),
    });
  }

  Future<McpCallOutcome> _triggerBuild(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final accountId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final guard = _guardProject(token, accountId, fullName);
    if (guard != null) return guard;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(accountId));
    if (repo == null) return _accountUnavailable(accountId);

    final overrides = <String, String>{};
    final rawParams = args['parameters'];
    if (rawParams is Map) {
      rawParams.forEach((k, v) {
        overrides[k.toString()] = v?.toString() ?? '';
      });
    }

    // 用项目参数定义补齐缺省值（参数化流水线必须带全量参数，否则常被 403/400 拒绝）。
    final detail = await repo.fetchJobDetail(fullName);
    final merged = BuildParameter.mergeForTrigger(detail.parameters, overrides);

    final queueUrl = await repo.triggerBuild(fullName, parameters: merged);
    final queueId = _queueIdFromUrl(queueUrl);

    // 立即返回（按设计不等待构建完成）；顺手探一次队列，若已分配构建号则一并带回。
    int? buildNumber;
    try {
      final item = await repo.fetchQueueItem(queueUrl);
      buildNumber = item?.executable?.number;
    } catch (_) {}

    return McpCallOutcome.ok({
      'accountId': accountId,
      'projectFullName': fullName,
      'queueUrl': queueUrl,
      'queueId': queueId,
      'buildNumber': buildNumber,
      'parameters': merged,
      'message': buildNumber != null
          ? '已开始构建 #$buildNumber'
          : '已加入队列，构建号稍后分配（可用 get_build_status 查询）',
    });
  }

  Future<McpCallOutcome> _getBuildStatus(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final accountId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final guard = _guardProject(token, accountId, fullName);
    if (guard != null) return guard;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(accountId));
    if (repo == null) return _accountUnavailable(accountId);

    var buildNumber = (args['buildNumber'] as num?)?.toInt();
    if (buildNumber == null) {
      final latest = await repo.fetchHistory(fullName, count: 1);
      if (latest.isEmpty) {
        return McpCallOutcome.ok({
          'accountId': accountId,
          'projectFullName': fullName,
          'found': false,
          'message': '该项目暂无构建记录。',
        });
      }
      buildNumber = latest.first.number;
    }

    final build = await repo.fetchBuild(fullName, buildNumber);
    final stages = await repo.fetchStages(fullName, buildNumber);

    final includeLog = args['includeLog'] as bool? ?? true;
    Map<String, dynamic>? log;
    if (includeLog) {
      final start = (args['logStart'] as num?)?.toInt() ?? 0;
      final l = await repo.fetchLog(fullName, buildNumber, start: start);
      log = {'text': l.text, 'hasMore': l.hasMore, 'nextStart': l.nextStart};
    }

    return McpCallOutcome.ok({
      'accountId': accountId,
      'projectFullName': fullName,
      'found': true,
      'build': _buildJson(build),
      'stages': stages.map(_stageJson).toList(growable: false),
      'log': ?log,
    });
  }

  Future<McpCallOutcome> _getReleaseHistory(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final accountId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final guard = _guardProject(token, accountId, fullName);
    if (guard != null) return guard;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(accountId));
    if (repo == null) return _accountUnavailable(accountId);

    final count = (args['count'] as num?)?.toInt() ?? 20;
    final rows = await repo.fetchReleaseHistory(
      fullName,
      count: count.clamp(1, 200),
    );
    return McpCallOutcome.ok({
      'accountId': accountId,
      'projectFullName': fullName,
      'history': rows.map(_historyJson).toList(growable: false),
    });
  }

  // ---------------- 作用域校验 ----------------

  McpCallOutcome? _guardAccount(McpToken token, String accountId) {
    if (accountId.isEmpty) {
      return const McpCallOutcome.error('缺少必填参数 accountId。');
    }
    if (!token.allowsAccount(accountId)) {
      return const McpCallOutcome.error('当前令牌无权访问该账号。');
    }
    return null;
  }

  McpCallOutcome? _guardProject(
    McpToken token,
    String accountId,
    String fullName,
  ) {
    final a = _guardAccount(token, accountId);
    if (a != null) return a;
    if (fullName.isEmpty) {
      return const McpCallOutcome.error('缺少必填参数 projectFullName。');
    }
    if (!token.allowsProject(fullName)) {
      return const McpCallOutcome.error('当前令牌无权访问该项目。');
    }
    return null;
  }

  McpCallOutcome _accountUnavailable(String accountId) =>
      McpCallOutcome.error('账号 $accountId 不存在或配置不完整。');

  // ---------------- 序列化 ----------------

  Map<String, dynamic> _projectJson(JenkinsNode n) => {
        'fullName': n.fullName,
        'name': n.name,
        'kind': n.kind.name,
        'buildable': n.buildable,
        'url': n.url,
        'lastBuildNumber': n.lastBuildNumber,
        'lastBuildResult': n.lastBuildResult,
      };

  Map<String, dynamic> _parameterJson(BuildParameter p) => {
        'name': p.name,
        'kind': p.kind.name,
        'defaultValue': p.defaultValue,
        'description': p.description,
        'choices': p.choices,
        'isLikelyBranch': p.isLikelyBranch,
      };

  Map<String, dynamic> _buildJson(JenkinsBuild b) => {
        'number': b.number,
        'url': b.url,
        'building': b.building,
        'result': b.result,
        'status': b.resultEnum.name,
        'timestamp': b.timestamp,
        'duration': b.duration,
        'estimatedDuration': b.estimatedDuration,
        'progress': b.progress,
        'displayName': b.displayName,
        'fullDisplayName': b.fullDisplayName,
      };

  Map<String, dynamic> _stageJson(BuildStage s) => {
        'id': s.id,
        'name': s.name,
        'status': s.status,
        'durationMillis': s.durationMillis,
        'startTimeMillis': s.startTimeMillis,
      };

  Map<String, dynamic> _historyJson(JenkinsReleaseHistoryRow r) => {
        'build': _buildJson(r.build),
        'parameters': r.parameters,
        'releasedBy': r.releasedBy,
        'gitRevision': r.gitRevision,
      };

  String _str(Object? v) => v?.toString().trim() ?? '';

  int? _queueIdFromUrl(String url) {
    final m = RegExp(r'/queue/item/(\d+)').firstMatch(url);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }
}
