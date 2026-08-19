import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/jenkins/data/jenkins_repository.dart';
import '../../../features/jenkins/domain/build_parameter.dart';
import '../../../features/jenkins/domain/jenkins_build.dart';
import '../../../features/jenkins/domain/jenkins_node.dart';
import '../../../features/jenkins/domain/jenkins_tree_transform.dart';
import '../../../features/settings/data/jenkins_accounts_repository.dart';
import '../../../features/settings/domain/jenkins_account.dart';
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
              // 对外只给不可逆哈希 id，绝不暴露用户名 / Jenkins 地址。
              'id': _externalAccountId(a.id),
              'name': a.displayName,
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
    final externalId = _str(args['accountId']);
    final (account, accountErr) = await _requireAccount(token, externalId);
    if (accountErr != null) return accountErr;

    final roots = await _ref.read(
      jenkinsTreeForAccountProvider(account!.id).future,
    );
    final projects = collectSidebarProjectNodes(roots)
        .where((n) => token.allowsProject(n.fullName))
        .map(_projectJson)
        .toList(growable: false);
    return McpCallOutcome.ok({
      'accountId': externalId,
      'projects': projects,
    });
  }

  Future<McpCallOutcome> _getProjectParameters(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final externalId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final (account, err) = await _requireProject(token, externalId, fullName);
    if (err != null) return err;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(account!.id));
    if (repo == null) return _accountUnavailable();

    final detail = await repo.fetchJobDetail(fullName);
    return McpCallOutcome.ok({
      'accountId': externalId,
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
    final externalId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final (account, err) = await _requireProject(token, externalId, fullName);
    if (err != null) return err;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(account!.id));
    if (repo == null) return _accountUnavailable();

    final overrides = <String, String>{};
    final rawParams = args['parameters'];
    if (rawParams is Map) {
      rawParams.forEach((k, v) {
        overrides[k.toString()] = v?.toString() ?? '';
      });
    }
    final waitSeconds =
        ((args['waitForBuildNumberSeconds'] as num?)?.toInt() ??
                kMcpDefaultTriggerWaitSeconds)
            .clamp(0, 180);

    // 用项目参数定义补齐缺省值（参数化流水线必须带全量参数，否则常被 403/400 拒绝）。
    final detail = await repo.fetchJobDetail(fullName);
    final merged = BuildParameter.mergeForTrigger(detail.parameters, overrides);

    final triggeredAt = DateTime.now().millisecondsSinceEpoch;
    final queueUrl = await repo.triggerBuild(fullName, parameters: merged);
    final queueId = _queueIdFromUrl(queueUrl);

    // 程序化调用必须拿到本次发版对应的构建号，否则同一项目连续多次发版无法关联。
    // 因此这里在 waitSeconds 内轮询队列项 / 构建历史，直到 Jenkins 分配构建号。
    // 注意：queueUrl 含 Jenkins 地址，绝不回传给调用方，只返回 queueId / buildNumber。
    final located = await _locateTriggeredBuild(
      repo: repo,
      fullName: fullName,
      queueUrl: queueUrl,
      queueId: queueId,
      triggeredAt: triggeredAt,
      waitSeconds: waitSeconds,
    );

    return McpCallOutcome.ok({
      'accountId': externalId,
      'projectFullName': fullName,
      // queueId 是「这一次触发」的唯一关联键：构建号还没分配时它也已确定，
      // 且可随时传给 get_build_status 换回构建号。
      'queueId': queueId,
      'buildNumber': located.buildNumber,
      'buildNumberSource': located.source,
      'queued': located.buildNumber == null && !located.cancelled,
      'cancelled': located.cancelled,
      'queueWhy': located.why,
      'triggeredAt': triggeredAt,
      'waitedMs': located.waitedMs,
      'parameters': merged,
      'message': _triggerMessage(located, queueId),
    });
  }

  String _triggerMessage(_LocatedBuild located, int? queueId) {
    if (located.cancelled) return '构建在队列中被取消，本次发版未开始。';
    final number = located.buildNumber;
    if (number != null) return '已开始构建 #$number';
    final handle = queueId != null
        ? '可用 get_build_status（传 queueId=$queueId）查询并换回构建号'
        : '可用 get_build_status 查询最近一次构建';
    final why = located.why;
    return '已加入队列但尚未分配构建号'
        '${why == null || why.isEmpty ? '' : '（$why）'}，$handle';
  }

  /// 在 [waitSeconds] 内定位本次触发对应的构建号。
  ///
  /// 优先级：队列项 `executable` → 按 queueId 反查构建历史 →（拿不到合法
  /// queue URL 时）按触发时间戳兜底。任一步命中即返回。
  Future<_LocatedBuild> _locateTriggeredBuild({
    required JenkinsRepository repo,
    required String fullName,
    required String queueUrl,
    required int? queueId,
    required int triggeredAt,
    required int waitSeconds,
  }) async {
    final started = DateTime.now();
    int elapsedMs() => DateTime.now().difference(started).inMilliseconds;
    // 部分 Jenkins / 反向代理触发后返回的 Location 不是 /queue/item/{N}/，
    // 那时既没有 queueId 也无法查队列项，只能按时间戳兜底。
    final hasQueueUrl = queueUrl.contains('/queue/item/');
    String? why;

    for (var round = 0;; round++) {
      // 队列项还在排队时它就是权威答案，本轮不必再扫历史，省一次请求。
      var stillQueued = false;
      if (hasQueueUrl) {
        try {
          final item = await repo.fetchQueueItem(queueUrl);
          if (item != null) {
            if (item.cancelled) {
              return _LocatedBuild(cancelled: true, waitedMs: elapsedMs());
            }
            final number = item.executable?.number;
            if (number != null && number > 0) {
              return _LocatedBuild(
                buildNumber: number,
                source: 'queue',
                waitedMs: elapsedMs(),
              );
            }
            stillQueued = item.isWaiting;
            final w = item.why;
            if (w != null && w.isNotEmpty) why = w;
          }
        } catch (_) {
          // 忽略：下面继续走历史反查
        }
      }

      if (queueId != null) {
        // 队列项已失效 / 拉不到时（少数 Jenkins 很快清掉出队项），按 queueId 反查历史。
        if (!stillQueued) {
          try {
            final number = await repo.findBuildNumberByQueueId(
              fullName,
              queueId,
            );
            if (number != null) {
              return _LocatedBuild(
                buildNumber: number,
                source: 'history-queueId',
                why: why,
                waitedMs: elapsedMs(),
              );
            }
          } catch (_) {}
        }
      } else {
        final number = await _buildNumberByTimestamp(
          repo,
          fullName,
          triggeredAt,
        );
        if (number != null) {
          return _LocatedBuild(
            buildNumber: number,
            source: 'history-timestamp',
            why: why,
            waitedMs: elapsedMs(),
          );
        }
      }

      if (elapsedMs() >= waitSeconds * 1000) {
        return _LocatedBuild(why: why, waitedMs: elapsedMs());
      }
      await Future<void>.delayed(
        Duration(milliseconds: round == 0 ? 500 : 1500),
      );
    }
  }

  /// 无 queueId 时的兜底：取触发时刻之后最早出现的那条构建。
  Future<int?> _buildNumberByTimestamp(
    JenkinsRepository repo,
    String fullName,
    int triggeredAt,
  ) async {
    try {
      const toleranceMs = 30 * 1000;
      final builds = await repo.fetchHistory(fullName, count: 10);
      final picked =
          builds.where((b) => b.timestamp >= triggeredAt - toleranceMs).toList()
            ..sort((a, b) => a.number.compareTo(b.number));
      return picked.isEmpty ? null : picked.first.number;
    } catch (_) {
      return null;
    }
  }

  Future<McpCallOutcome> _getBuildStatus(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final externalId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final (account, err) = await _requireProject(token, externalId, fullName);
    if (err != null) return err;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(account!.id));
    if (repo == null) return _accountUnavailable();

    final queueId = (args['queueId'] as num?)?.toInt();
    var buildNumber = (args['buildNumber'] as num?)?.toInt();

    // 传了 queueId 就按「本次触发」精确定位，避免并发发版时读到别人的构建。
    if (buildNumber == null && queueId != null) {
      final resolved = await _resolveQueuedBuildNumber(repo, fullName, queueId);
      if (resolved.buildNumber == null) {
        return McpCallOutcome.ok({
          'accountId': externalId,
          'projectFullName': fullName,
          'queueId': queueId,
          'found': false,
          'queued': !resolved.cancelled,
          'cancelled': resolved.cancelled,
          'queueWhy': resolved.why,
          'message': resolved.cancelled
              ? '该次发版在队列中被取消。'
              : '该次发版仍在队列中，尚未分配构建号，请稍后重试。',
        });
      }
      buildNumber = resolved.buildNumber;
    }

    if (buildNumber == null) {
      final latest = await repo.fetchHistory(fullName, count: 1);
      if (latest.isEmpty) {
        return McpCallOutcome.ok({
          'accountId': externalId,
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
      'accountId': externalId,
      'projectFullName': fullName,
      'queueId': ?queueId,
      'found': true,
      'buildNumber': buildNumber,
      'build': _buildJson(build),
      'stages': stages.map(_stageJson).toList(growable: false),
      'log': ?log,
    });
  }

  /// 由 queueId 换回构建号：先查队列项，队列项已过期再到构建历史里反查。
  Future<_LocatedBuild> _resolveQueuedBuildNumber(
    JenkinsRepository repo,
    String fullName,
    int queueId,
  ) async {
    String? why;
    var cancelled = false;
    try {
      final item = await repo.fetchQueueItemById(queueId);
      if (item != null) {
        cancelled = item.cancelled;
        why = item.why;
        final number = item.executable?.number;
        if (number != null && number > 0) {
          return _LocatedBuild(buildNumber: number, source: 'queue');
        }
      }
    } catch (_) {
      // 队列项 404 / 过期都走下面的历史反查
    }
    final fromHistory = await repo.findBuildNumberByQueueId(fullName, queueId);
    if (fromHistory != null) {
      return _LocatedBuild(buildNumber: fromHistory, source: 'history-queueId');
    }
    return _LocatedBuild(cancelled: cancelled, why: why);
  }

  Future<McpCallOutcome> _getReleaseHistory(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final externalId = _str(args['accountId']);
    final fullName = _str(args['projectFullName']);
    final (account, err) = await _requireProject(token, externalId, fullName);
    if (err != null) return err;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(account!.id));
    if (repo == null) return _accountUnavailable();

    final count = (args['count'] as num?)?.toInt() ?? 20;
    final rows = await repo.fetchReleaseHistory(
      fullName,
      count: count.clamp(1, 200),
    );
    return McpCallOutcome.ok({
      'accountId': externalId,
      'projectFullName': fullName,
      'history': rows.map(_historyJson).toList(growable: false),
    });
  }

  // ---------------- 账号解析 + 作用域校验 ----------------

  /// 对外账号标识：内部真实 id（含用户名@域名）的 SHA-256 前 16 位十六进制。
  /// 单向、稳定，调用方可跨次复用，但无法据此反推任何明文。
  String _externalAccountId(String realId) {
    final digest = sha256.convert(utf8.encode(realId));
    return 'acct_${digest.toString().substring(0, 16)}';
  }

  /// 由对外哈希 id 反查内部账号，并校验令牌作用域。
  Future<(JenkinsAccount?, McpCallOutcome?)> _requireAccount(
    McpToken token,
    String externalId,
  ) async {
    if (externalId.isEmpty) {
      return (null, const McpCallOutcome.error('缺少必填参数 accountId。'));
    }
    final state = await _ref.read(jenkinsAccountsProvider.future);
    JenkinsAccount? found;
    for (final a in state.accounts) {
      if (_externalAccountId(a.id) == externalId) {
        found = a;
        break;
      }
    }
    if (found == null) {
      return (null, const McpCallOutcome.error('账号不存在或无权访问。'));
    }
    if (!token.allowsAccount(found.id)) {
      return (null, const McpCallOutcome.error('当前令牌无权访问该账号。'));
    }
    return (found, null);
  }

  Future<(JenkinsAccount?, McpCallOutcome?)> _requireProject(
    McpToken token,
    String externalId,
    String fullName,
  ) async {
    final (account, err) = await _requireAccount(token, externalId);
    if (err != null) return (null, err);
    if (fullName.isEmpty) {
      return (null, const McpCallOutcome.error('缺少必填参数 projectFullName。'));
    }
    if (!token.allowsProject(fullName)) {
      return (null, const McpCallOutcome.error('当前令牌无权访问该项目。'));
    }
    return (account, null);
  }

  McpCallOutcome _accountUnavailable() =>
      const McpCallOutcome.error('账号不存在或配置不完整。');

  // ---------------- 序列化（不含任何 Jenkins 地址 / 用户名）----------------

  Map<String, dynamic> _projectJson(JenkinsNode n) => {
        'fullName': n.fullName,
        'name': n.name,
        'kind': n.kind.name,
        'buildable': n.buildable,
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
        // 关联「哪一次触发产生了这条构建」，程序化调用据此对账。
        'queueId': b.queueId,
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

/// `trigger_build` / `get_build_status` 定位构建号的中间结果。
class _LocatedBuild {
  const _LocatedBuild({
    this.buildNumber,
    this.source,
    this.why,
    this.cancelled = false,
    this.waitedMs = 0,
  });

  final int? buildNumber;

  /// 构建号来源：queue / history-queueId / history-timestamp；未定位到为 null。
  final String? source;

  /// Jenkins 给出的排队原因（如「等待可用执行器」）。
  final String? why;
  final bool cancelled;
  final int waitedMs;
}
