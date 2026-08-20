import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/jenkins_http_client.dart';
import '../../../plug/network_proxy/network_proxy_state.dart';
import '../../settings/application/network_proxy_state_provider.dart';
import '../../settings/data/jenkins_accounts_repository.dart';
import '../../settings/domain/jenkins_config.dart';
import '../domain/build_parameter.dart';
import '../domain/jenkins_build.dart';
import '../domain/jenkins_node.dart';
import '../domain/ref_option.dart';
import '../domain/trigger_result.dart';
import 'jenkins_api.dart';

/// 高层 Repository。封装错误转换 + 简单缓存。
class JenkinsRepository {
  JenkinsRepository(this._api);

  final JenkinsApi _api;

  /// 缓存每个 Job 的 `_class`（来自 `fetchJobDetail`）。
  /// triggerBuild 用它来跳过 Pipeline 不支持的 `buildWithParameters` 探测。
  final Map<String, String> _jobClassCache = {};

  /// 缓存 (jobFullName -> paramName -> 历史出现过的分支/Tag 值)。
  ///
  /// 同一项目同一参数在一次会话里被反复打开下拉时不需要每次再去拉构建历史；
  /// 用户如果需要刷新，可以调 [refreshBranchOptions]。
  final Map<String, Map<String, List<RefOption>>> _branchOptionsCache = {};

  Future<({String version, String? mode})> ping() async {
    try {
      return await _api.ping();
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<List<JenkinsNode>> fetchTree({int depth = 4}) async {
    try {
      return await _api.fetchTree(depth: depth);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<({Map<String, dynamic> raw, List<BuildParameter> parameters})>
  fetchJobDetail(String fullName) async {
    try {
      final raw = await _api.fetchJobDetail(fullName);
      final cls = raw['_class'] as String?;
      if (cls != null && cls.isNotEmpty) {
        _jobClassCache[fullName] = cls;
      }
      final params = _api.parseParameters(raw);
      return (raw: raw, parameters: params);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<JenkinsBuild> fetchBuild(String jobFullName, int buildNumber) async {
    try {
      return await _api.fetchBuild(jobFullName, buildNumber);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<List<JenkinsBuild>> fetchHistory(
    String jobFullName, {
    int count = 20,
  }) async {
    try {
      return await _api.fetchBuildHistory(jobFullName, count: count);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 最近构建记录（含参数快照），用于项目页「历史发版记录」。
  Future<List<JenkinsReleaseHistoryRow>> fetchReleaseHistory(
    String jobFullName, {
    int count = 40,
  }) async {
    try {
      return await _api.fetchReleaseHistory(jobFullName, count: count);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<TriggerResult> triggerBuild(
    String jobFullName, {
    Map<String, String> parameters = const {},
  }) async {
    try {
      return await _api.triggerBuild(
        jobFullName,
        parameters: parameters,
        jobClass: _jobClassCache[jobFullName],
      );
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<void> stopBuild(String jobFullName, int buildNumber) async {
    try {
      await _api.stopBuild(jobFullName, buildNumber);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 拉「该 Job × 该参数」可能的分支/Tag 候选集合（带类型），命中缓存就直接返回。
  ///
  /// 优先调用 Git Parameter Plugin 的 `fillValueItems` 接口（返回远端全量 ref + 类型信息）；
  /// 若该接口返回空（非 Git Parameter 参数或权限不足），降级为扫描历史构建记录。
  Future<List<RefOption>> fetchBranchOptions(
    String jobFullName,
    String paramName, {
    int count = 50,
    bool forceRefresh = false,
  }) async {
    final perJob = _branchOptionsCache[jobFullName] ??= {};
    if (!forceRefresh) {
      final cached = perJob[paramName];
      if (cached != null) return cached;
    }
    try {
      // 先尝试 Git Parameter Plugin 接口，能拿到远端所有分支 + tag。
      final gitParamValues = await _api.fetchGitParameterValues(jobFullName, paramName);
      if (gitParamValues.isNotEmpty) {
        perJob[paramName] = gitParamValues;
        return gitParamValues;
      }
      // 降级：扫描历史构建参数值。
      final values = await _api.fetchHistoricalParameterValues(
        jobFullName,
        paramName,
        count: count,
      );
      perJob[paramName] = values;
      return values;
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 丢弃与该 Job 相关的进程内缓存（关闭标签页、强制重新打开等）。
  void invalidateJobDetailCaches(String jobFullName) {
    _jobClassCache.remove(jobFullName);
    _branchOptionsCache.remove(jobFullName);
  }

  /// 让调用方主动丢弃缓存（例如「刷新分支」按钮）。
  void invalidateBranchOptions(String jobFullName, [String? paramName]) {
    if (paramName == null) {
      _branchOptionsCache.remove(jobFullName);
    } else {
      _branchOptionsCache[jobFullName]?.remove(paramName);
    }
  }

  Future<QueueItem?> pollQueueItem(String queueUrl) async {
    try {
      return await _api.pollQueueItem(queueUrl);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<QueueItem?> fetchQueueItem(String queueUrl) async {
    try {
      return await _api.fetchQueueItem(queueUrl);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 只知道 queueId 时用它复查队列项（队列项约 5 分钟后过期）。
  Future<QueueItem?> fetchQueueItemById(int queueId) async {
    try {
      return await _api.fetchQueueItemById(queueId);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 列出队列里属于该项目的排队项；触发接口没给出 `/queue/item/{id}/` 时用它认领。
  Future<List<QueueItem>> fetchQueueItemsForJob(String jobFullName) async {
    try {
      return await _api.fetchQueueItemsForJob(jobFullName);
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  /// 按 queueId 在构建历史里反查构建号；找不到返回 null。
  Future<int?> findBuildNumberByQueueId(
    String jobFullName,
    int queueId, {
    int count = 30,
  }) async {
    try {
      return await _api.findBuildNumberByQueueId(
        jobFullName,
        queueId,
        count: count,
      );
    } catch (e) {
      throw toJenkinsException(e);
    }
  }

  Future<List<BuildStage>> fetchStages(String jobFullName, int buildNumber) =>
      _api.fetchStages(jobFullName, buildNumber);

  Future<({String text, bool hasMore, int nextStart})> fetchLog(
    String jobFullName,
    int buildNumber, {
    int start = 0,
  }) async {
    try {
      return await _api.fetchProgressiveLog(
        jobFullName,
        buildNumber,
        start: start,
      );
    } catch (e) {
      throw toJenkinsException(e);
    }
  }
}

class _JenkinsNetworkProxySelection {
  const _JenkinsNetworkProxySelection(this.state);

  final NetworkProxyState state;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _JenkinsNetworkProxySelection) return false;
    final a = state;
    final b = other.state;
    return a.role == b.role &&
        a.client.enabled == b.client.enabled &&
        a.client.encrypted == b.client.encrypted &&
        a.client.host == b.client.host &&
        a.client.port == b.client.port &&
        a.client.username == b.client.username &&
        a.client.password == b.client.password &&
        _listEquals(a.client.noProxyHosts, b.client.noProxyHosts);
  }

  @override
  int get hashCode {
    final c = state.client;
    return Object.hash(
      state.role,
      c.enabled,
      c.encrypted,
      c.host,
      c.port,
      c.username,
      c.password,
      Object.hashAll(c.noProxyHosts),
    );
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

NetworkProxyState _watchJenkinsNetworkProxy(Ref ref) {
  return ref
      .watch(
        networkProxyStateProvider.select(_JenkinsNetworkProxySelection.new),
      )
      .state;
}

/// 指定 Jenkins 登录账号的 Repository（独立 Dio，供多账号工作区并存）。
final jenkinsRepositoryForAccountProvider =
    Provider.family<JenkinsRepository?, String>((ref, accountId) {
      final account = ref.watch(
        jenkinsAccountsProvider.select((async) {
          final list = async.value?.accounts;
          if (list == null) return null;
          for (final a in list) {
            if (a.id == accountId) return a;
          }
          return null;
        }),
      );
      if (account == null || !account.config.isComplete) return null;

      final networkProxy = _watchJenkinsNetworkProxy(ref);

      final dio = buildJenkinsDio(
        baseUrl: account.config.baseUrl,
        credentials: account.config.toCredentials(),
        networkProxy: networkProxy,
      );
      ref.onDispose(() => dio.close(force: true));
      return JenkinsRepository(JenkinsApi(dio));
    });

/// 与当前全局「激活」账号一致（侧栏、状态栏等单上下文入口）。
final jenkinsRepositoryProvider = Provider<JenkinsRepository?>((ref) {
  final id = ref.watch(jenkinsAccountsProvider).value?.activeId;
  if (id == null) return null;
  return ref.watch(jenkinsRepositoryForAccountProvider(id));
});

/// 侧栏项目树强制刷新信号（按 Jenkins 账号 id）。
///
/// [jenkinsTreeForAccountProvider] 会 watch 此处计数。
///
/// - 侧栏刷新 / 错误重试：直接 [bump]。
/// - **关闭再打开一级标签**：须在重新加入一级栏时 bump（见 [WorkspaceController.openAccountInStrip]），
///   仅在关闭时 bump 往往没有 listener，family 不会重建。
class JenkinsTreeReloadSignal extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => {};

  void bump(String accountId) {
    state = {...state, accountId: (state[accountId] ?? 0) + 1};
  }
}

final jenkinsTreeReloadSignalProvider =
    NotifierProvider<JenkinsTreeReloadSignal, Map<String, int>>(
      JenkinsTreeReloadSignal.new,
    );

/// 指定 Jenkins 账号下的节点树（按账号 id 缓存；切换一级 tab 不会触发其它账号重新拉取）。
///
/// 仅当该账号在列表中的配置变更时才会重建并重新请求。
final jenkinsTreeForAccountProvider =
    FutureProvider.family<List<JenkinsNode>, String>((ref, accountId) async {
      // 切换一级 tab 时短时取消监听，保留已拉取的树，避免来回切换重复打 Jenkins。
      ref.keepAlive();

      ref.watch(
        jenkinsTreeReloadSignalProvider.select((m) => m[accountId] ?? 0),
      );

      final account = ref.watch(
        jenkinsAccountsProvider.select((async) {
          final list = async.value?.accounts;
          if (list == null) return null;
          for (final a in list) {
            if (a.id == accountId) return a;
          }
          return null;
        }),
      );
      if (account == null || !account.config.isComplete) return const [];

      final dio = buildJenkinsDio(
        baseUrl: account.config.baseUrl,
        credentials: account.config.toCredentials(),
        networkProxy: _watchJenkinsNetworkProxy(ref),
      );
      try {
        return await JenkinsApi(dio).fetchTree(depth: 4);
      } catch (e) {
        throw toJenkinsException(e);
      } finally {
        dio.close(force: true);
      }
    });

/// 仅一次性测试连接：不与全局 config 关联，直接用入参构造 Dio。
Future<({String version, String? mode})> testJenkinsConnection(
  JenkinsConfig config, {
  NetworkProxyState networkProxy = NetworkProxyState.defaults,
}) async {
  final dio = buildJenkinsDio(
    baseUrl: config.baseUrl,
    credentials: config.toCredentials(),
    networkProxy: networkProxy,
  );
  try {
    return await JenkinsApi(dio).ping();
  } catch (e) {
    throw toJenkinsException(e);
  } finally {
    dio.close(force: true);
  }
}
