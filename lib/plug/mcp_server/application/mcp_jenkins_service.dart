import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/jenkins/application/build_attribution_provider.dart';
import '../../../features/jenkins/data/jenkins_repository.dart';
import '../../../features/jenkins/domain/build_attribution.dart';
import '../../../features/jenkins/domain/build_parameter.dart';
import '../../../features/jenkins/domain/jenkins_build.dart';
import '../../../features/jenkins/domain/jenkins_node.dart';
import '../../../features/jenkins/domain/jenkins_tree_transform.dart';
import '../../../features/jenkins/domain/trigger_result.dart';
import '../../../features/settings/data/jenkins_accounts_repository.dart';
import '../../../features/settings/domain/jenkins_account.dart';
import '../core/mcp_protocol.dart';
import '../core/mcp_token.dart';
import '../core/mcp_tool_specs.dart';
import 'mcp_server_log_provider.dart';
import 'mcp_server_state_provider.dart';
import 'mcp_trigger_registry.dart';

/// 把 MCP 工具调用翻译为对既有 Jenkins 仓储 / Provider 的读取，
/// 并按调用令牌的作用域（允许的账号 / 项目）做访问控制。
class McpJenkinsService {
  McpJenkinsService(this._ref);

  final Ref _ref;

  /// 每次 trigger_build 的台账：发 triggerId，并记录哪个 queueId / 构建号
  /// 已经属于哪一次触发（同一项目连续多次发版靠它避免串号）。
  final McpTriggerRegistry _triggers = McpTriggerRegistry();

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

    // 触发前拉一次最新构建号作为事实下界：本次构建号必然大于它。
    var historyFloor = 0;
    try {
      final latest = await repo.fetchHistory(fullName, count: 1);
      if (latest.isNotEmpty) historyFloor = latest.first.number;
    } catch (_) {
      // 拉不到不致命：下界退化为 0，仍有参数比对 + 认领兜底
    }

    // 先开台账再触发：triggerId 与 Jenkins 无关，永远唯一且不为 null，
    // 是调用方区分「同一项目第 N 次发版」的键；queueId / 构建号随后回填。
    final record = _triggers.open(
      accountId: externalId,
      // 与发版 UI 同一口径的归属键（内部账号 id + 项目全名），
      // 两条通道共用一份台账才不会互相认错构建。
      attributionKey: '${account.id}::$fullName',
      // 账号登录名：兜底认亲时用来排除同事在 Jenkins 上手动触发的构建。
      accountUserId: account.config.username.trim(),
      projectFullName: fullName,
      triggeredAt: DateTime.now().millisecondsSinceEpoch,
      parameters: merged,
      historyFloor: historyFloor,
    );
    final trigger = await repo.triggerBuild(fullName, parameters: merged);
    record.queueId = _queueIdFromUrl(trigger.location);
    if (record.queueId != null) record.queueIdSource = 'location';
    _logTriggerDiagnostics(fullName, record, trigger);

    // 程序化调用必须拿到本次发版对应的构建号，否则同一项目连续多次发版无法关联。
    // 因此这里在 waitSeconds 内轮询队列 / 构建历史，直到 Jenkins 分配构建号。
    // 注意：queueUrl 含 Jenkins 地址，绝不回传给调用方，只返回 triggerId / queueId /
    // buildNumber。
    final located = await _locateTriggeredBuild(
      repo: repo,
      record: record,
      waitSeconds: waitSeconds,
    );
    record.buildNumber = located.buildNumber;
    record.cancelled = located.cancelled;

    return McpCallOutcome.ok({
      'accountId': externalId,
      'projectFullName': fullName,
      // triggerId：本次触发的唯一键，触发即确定、永不为 null，
      // 随时可传给 get_build_status 换回发版号。
      'triggerId': record.triggerId,
      // queueId：Jenkins 侧队列项 id，能拿到时可跨进程复查；
      // 部分实例 / 反向代理不返回 /queue/item/{id}/ 时为 null，此时以 triggerId 为准。
      'queueId': record.queueId,
      'queueIdSource': record.queueIdSource,
      // 为什么这次没拿到 queueId：把触发响应的状态码 / 命中策略 / 各次尝试摊开，
      // 便于调用方与我们排查（不含 Jenkins 地址与响应体）。
      'triggerDiagnostics': _triggerDiagnosticsJson(trigger),
      'buildNumber': located.buildNumber,
      'buildNumberSource': located.source,
      'queued': located.buildNumber == null && !located.cancelled,
      'cancelled': located.cancelled,
      'queueWhy': located.why,
      'triggeredAt': record.triggeredAt,
      'waitedMs': located.waitedMs,
      'parameters': merged,
      'message': _triggerMessage(located, record),
    });
  }

  /// 把触发过程写进 MCP 日志面板。
  ///
  /// `location` 只记路径（去掉 Jenkins 地址），4xx 的响应体片段只留在本机日志里，
  /// 这是排查「为什么 buildWithParameters 返回 400 → 退化到 json=/build →
  /// 没有 /queue/item/ → queueId 为 null」的唯一线索。
  void _logTriggerDiagnostics(
    String fullName,
    McpTriggerRecord record,
    TriggerResult trigger,
  ) {
    final log = _ref.read(mcpServerLogProvider.notifier);
    log.add(
      'trigger_build $fullName：HTTP ${trigger.statusCode} '
      'strategy=${trigger.strategy}(${trigger.endpoint}) '
      'location=${trigger.locationPath} '
      'queueId=${record.queueId ?? 'null'} '
      'triggerId=${record.triggerId}',
    );
    if (!trigger.isQueueItemLocation) {
      log.add(
        '  ↳ Location 不是 /queue/item/{id}/，本次无法从触发响应拿到 queueId，'
        '将改为扫描队列 / 构建历史认领。',
      );
    }
    for (final a in trigger.attempts.where((a) => a.statusCode >= 400)) {
      log.add('  ↳ 失败尝试 $a');
    }
  }

  /// 回传给调用方的诊断（脱敏：不含 Jenkins 地址、不含响应体）。
  Map<String, dynamic> _triggerDiagnosticsJson(TriggerResult trigger) => {
        'status': trigger.statusCode,
        'strategy': trigger.strategy,
        'endpoint': trigger.endpoint,
        'locationIsQueueItem': trigger.isQueueItemLocation,
        'attempts': trigger.attempts
            .map((a) => {
                  'strategy': a.strategy,
                  'endpoint': a.endpoint,
                  'status': a.statusCode,
                })
            .toList(growable: false),
      };

  String _triggerMessage(_LocatedBuild located, McpTriggerRecord record) {
    if (located.cancelled) return '构建在队列中被取消，本次发版未开始。';
    final number = located.buildNumber;
    if (number != null) {
      return '已开始构建 #$number（triggerId=${record.triggerId}）';
    }
    final why = located.why;
    return '已加入队列但尚未分配构建号'
        '${why == null || why.isEmpty ? '' : '（$why）'}，'
        '可用 get_build_status（传 triggerId=${record.triggerId}）查询并换回构建号';
  }

  /// 在 [waitSeconds] 内定位本次触发对应的构建号，并把认领到的 queueId 回填进
  /// [record]。
  ///
  /// 优先级：队列项 `executable` → 按 queueId 反查构建历史 → 按触发时间戳兜底
  /// （兜底会跳过已被其它触发认领的构建，避免同一项目连续触发串号）。
  Future<_LocatedBuild> _locateTriggeredBuild({
    required JenkinsRepository repo,
    required McpTriggerRecord record,
    required int waitSeconds,
  }) async {
    final started = DateTime.now();
    int elapsedMs() => DateTime.now().difference(started).inMilliseconds;
    String? why;

    for (var round = 0;; round++) {
      // 触发响应没给出 /queue/item/{id}/ 时，到队列里认领一个属于本项目、
      // 尚未被其它触发占用的排队项，把 queueId 补回来。
      if (record.queueId == null) {
        record.queueId = await _claimQueueId(repo, record);
        if (record.queueId != null) record.queueIdSource = 'queue-scan';
      }

      var stillQueued = false;
      final queueId = record.queueId;
      if (queueId != null) {
        try {
          final item = await repo.fetchQueueItemById(queueId);
          if (item != null) {
            if (item.cancelled) {
              return _LocatedBuild(cancelled: true, waitedMs: elapsedMs());
            }
            final number = item.executable?.number;
            // 队列项是 Jenkins 给的权威答案，但仍要过一道事实下界：号必须大于
            // 触发前的最新号，否则说明这个队列项 stale、executable 指着上一条
            // build（与发版 UI 同一道校验）。不达标就继续等，不返回错号。
            if (number != null && number > record.historyFloor) {
              // 认领失败说明 Jenkins 把两次同参数触发合并成了一条 build，
              // 那时本就该指向同一个号，不影响结论。
              _claimBuild(record, number);
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
        // 队列项已失效 / 拉不到时（少数 Jenkins 很快清掉出队项），按 queueId 反查历史。
        if (!stillQueued) {
          try {
            final number = await repo.findBuildNumberByQueueId(
              record.projectFullName,
              queueId,
            );
            if (number != null) {
              _claimBuild(record, number);
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
        // 连排队项都认领不到（触发后立刻出队 / 队列接口不可读）：按时间戳兜底。
        final picked = await _claimBuildFromHistory(repo, record);
        if (picked != null) {
          if (record.queueId == null && picked.queueId != null) {
            record.queueId = picked.queueId;
            record.queueIdSource = 'history';
          }
          record.buildNumber = picked.number;
          return _LocatedBuild(
            buildNumber: picked.number,
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

  /// 从 Jenkins 队列里认领一个属于本次触发的排队项 id；认领不到返回 null。
  Future<int?> _claimQueueId(
    JenkinsRepository repo,
    McpTriggerRecord record,
  ) async {
    try {
      final items = await repo.fetchQueueItemsForJob(record.projectFullName);
      return pickOwnQueueItemId(
        items,
        record.parameters,
        (id) => _triggers.isQueueIdClaimed(
          record.projectFullName,
          id,
          exceptTriggerId: record.triggerId,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 登记「这条构建属于本次触发」；已被别人占用时返回 false。
  bool _claimBuild(McpTriggerRecord record, int buildNumber) => _ref
      .read(buildAttributionRegistryProvider)
      .claim(record.attributionKey, buildNumber, record.triggerId);

  /// 无 queueId 时的兜底：在构建历史里按参数快照认亲。
  ///
  /// 判定逻辑与发版 UI 共用 [pickOwnBuild]：事实下界 + 参数快照 + 原子认领，
  /// 因此既不会把同事在 Jenkins 上手动触发的构建认成自己的，也不会和 UI tab
  /// 抢同一条构建。认不到就返回 null，让调用方用 triggerId 稍后再查。
  Future<JenkinsBuild?> _claimBuildFromHistory(
    JenkinsRepository repo,
    McpTriggerRecord record,
  ) async {
    try {
      final rows = await repo.fetchReleaseHistory(
        record.projectFullName,
        count: 10,
      );
      final picked = pickOwnBuild(
        rows: rows,
        triggeredAt: record.triggeredAt,
        historyFloor: record.historyFloor,
        triggeredParameters: record.parameters,
        tryClaim: (number) => _claimBuild(record, number),
        expectedUserId: record.accountUserId,
      );
      return picked?.build;
    } catch (_) {
      return null;
    }
  }

  Future<McpCallOutcome> _getBuildStatus(
    McpToken token,
    Map<String, dynamic> args,
  ) async {
    final triggerId = _str(args['triggerId']);
    final record = _triggers.byId(triggerId);
    if (triggerId.isNotEmpty && record == null) {
      return const McpCallOutcome.error(
        'triggerId 无效或已过期（服务重启 / 记录被淘汰）。'
        '请改用 buildNumber 或 queueId 查询，或重新 trigger_build。',
      );
    }
    // 传了 triggerId 就以台账里的项目为准，避免调用方把项目名写错导致查错项目。
    final externalId = record?.accountId ?? _str(args['accountId']);
    final fullName = record?.projectFullName ?? _str(args['projectFullName']);
    final (account, err) = await _requireProject(token, externalId, fullName);
    if (err != null) return err;
    final repo = _ref.read(jenkinsRepositoryForAccountProvider(account!.id));
    if (repo == null) return _accountUnavailable();

    var queueId = (args['queueId'] as num?)?.toInt() ?? record?.queueId;
    var buildNumber =
        (args['buildNumber'] as num?)?.toInt() ?? record?.buildNumber;

    // 定位优先级：显式 buildNumber > 台账已记住的构建号 > queueId 反查 >
    // 用 triggerId 现场认领（队列项 / 时间戳兜底）> 最近一次构建。
    var cancelled = record?.cancelled ?? false;
    String? queueWhy;
    if (buildNumber == null && queueId == null && record != null) {
      queueId = await _claimQueueId(repo, record);
      record.queueId = queueId;
      if (queueId != null) record.queueIdSource = 'queue-scan';
    }
    if (buildNumber == null && queueId != null) {
      final resolved = await _resolveQueuedBuildNumber(
        repo,
        fullName,
        queueId,
        historyFloor: record?.historyFloor ?? 0,
      );
      buildNumber = resolved.buildNumber;
      cancelled = cancelled || resolved.cancelled;
      queueWhy = resolved.why;
    }
    if (buildNumber == null && record != null && !cancelled) {
      final picked = await _claimBuildFromHistory(repo, record);
      buildNumber = picked?.number;
      if (record.queueId == null && picked?.queueId != null) {
        record.queueId = picked!.queueId;
        record.queueIdSource = 'history';
      }
    }
    record?.buildNumber = buildNumber;
    record?.cancelled = cancelled;

    // 指定了某一次触发但还没分配构建号：明确回 queued，不要退回「最近一次构建」，
    // 否则并发发版时会读到别人的构建。
    if (buildNumber == null && (record != null || queueId != null)) {
      return McpCallOutcome.ok({
        'accountId': externalId,
        'projectFullName': fullName,
        'triggerId': ?record?.triggerId,
        'queueId': queueId,
        'found': false,
        'queued': !cancelled,
        'cancelled': cancelled,
        'queueWhy': queueWhy,
        'message': cancelled
            ? '该次发版在队列中被取消。'
            : '该次发版仍在队列中，尚未分配构建号，请稍后重试。',
      });
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
      'triggerId': ?record?.triggerId,
      'queueId': ?queueId,
      'found': true,
      'buildNumber': buildNumber,
      'build': _buildJson(build),
      'stages': stages.map(_stageJson).toList(growable: false),
      'log': ?log,
    });
  }

  /// 由 queueId 换回构建号：先查队列项，队列项已过期再到构建历史里反查。
  ///
  /// [historyFloor] 是触发前该 Job 的最新构建号（只有经本服务触发、能查到台账
  /// 时才有）。给了就用它挡掉 stale 队列项指向的旧 build；调用方只给 queueId
  /// 时无从校验，传 0 即可。
  Future<_LocatedBuild> _resolveQueuedBuildNumber(
    JenkinsRepository repo,
    String fullName,
    int queueId, {
    int historyFloor = 0,
  }) async {
    String? why;
    var cancelled = false;
    try {
      final item = await repo.fetchQueueItemById(queueId);
      if (item != null) {
        cancelled = item.cancelled;
        why = item.why;
        final number = item.executable?.number;
        if (number != null && number > historyFloor) {
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
    final attributionKey = '${account.id}::$fullName';
    return McpCallOutcome.ok({
      'accountId': externalId,
      'projectFullName': fullName,
      'history': rows
          .map((r) => _historyJson(r, attributionKey))
          .toList(growable: false),
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

  Map<String, dynamic> _historyJson(
    JenkinsReleaseHistoryRow r,
    String attributionKey,
  ) => {
        'build': _buildJson(r.build),
        'parameters': r.parameters,
        'releasedBy': r.releasedBy,
        'gitRevision': r.gitRevision,
        // 这条构建是本服务哪一次 trigger_build 打出来的；不是经本服务触发
        //（UI 发的 / 别人在 Jenkins 上手动发的 / 服务重启前的）则为 null。
        // 有了它，调用方可以拿历史反查「我那次发版最后跑成什么样」。
        'triggerId': _triggerIdForBuild(attributionKey, r.build.number),
      };

  /// 反查某条构建对应的 triggerId。
  ///
  /// 归属台账里的 owner 也可能是发版 UI 的 runId，所以要回台账确认这个 owner
  /// 真的是一次 MCP 触发，避免把 UI 的内部标识泄露给调用方。
  String? _triggerIdForBuild(String attributionKey, int buildNumber) {
    final owner = _ref
        .read(buildAttributionRegistryProvider)
        .ownerOf(attributionKey, buildNumber);
    if (owner == null) return null;
    return _triggers.byId(owner) == null ? null : owner;
  }

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
