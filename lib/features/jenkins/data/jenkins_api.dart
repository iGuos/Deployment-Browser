import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/http/jenkins_http_client.dart';
import '../domain/build_parameter.dart';
import '../domain/jenkins_build.dart';
import '../domain/jenkins_node.dart';
import '../domain/ref_option.dart';

/// 合成视图文件夹节点使用的 [JenkinsNode.fullName] 前缀（非 Jenkins 真实路径）。
const String kJenkinsSyntheticViewFullNamePrefix = '__jenkins_view__/';

/// 直接对 Jenkins HTTP API 的封装。
///
/// 不持有状态，仅做请求 + 解析。Repository 层在其上做聚合 / 缓存 / 错误转换。
class JenkinsApi {
  JenkinsApi(this._dio);

  final Dio _dio;
  _CrumbCache? _crumb;

  // Jenkins crumb 与服务端 session 绑定；session 过期后旧 crumb 必然 403。
  // 设一个比常见 idle timeout 短得多的 TTL，强制定期重拉，避免长时间不操作后第一次发版失败。
  static const Duration _crumbTtl = Duration(minutes: 5);

  /// 进程内记录每个 Job 上次成功的触发策略编号。
  ///
  /// Pipeline / Workflow 类 Job 拒绝 `buildWithParameters` 是常态，
  /// 第一次会按 0..N 串行探测；命中后这里缓存对应 strategy，下次同 Job
  /// 直接从该策略起步，省掉一连串 400 探测。
  final Map<String, int> _successStrategy = {};

  /// 测试连接：抓 `/api/json` 的 mode 字段以确认是 Jenkins。
  Future<({String version, String? mode})> ping() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/json');
    if (res.statusCode != 200) {
      throw toJenkinsException(DioException(
        requestOptions: res.requestOptions,
        response: res,
        type: DioExceptionType.badResponse,
      ));
    }
    final version = res.headers.value('x-jenkins') ?? '';
    return (version: version, mode: res.data?['mode'] as String?);
  }

  /// 拉取整棵节点树。`depth` 越大递归越深，对大型 Jenkins 调小一点。
  ///
  /// 除根级 [jobs] 外，会一并拉取 [views]：每个非 “All” 的视图会渲染为可展开的
  /// 合成文件夹（[fullName] 形如 `__jenkins_view__/视图名`），其下为该视图内的 Job。
  /// 已在任一视图树中出现的 Job 会从根 [jobs] 列表中剔除，避免与视图分组重复展示。
  Future<List<JenkinsNode>> fetchTree({int depth = 4}) async {
    final jobsTree = _treeQuery(depth);
    final tree = '$jobsTree,views[name,url,$jobsTree]';
    final res = await _dio.get<Map<String, dynamic>>('/api/json', queryParameters: {
      'tree': tree,
    });
    final rootJobsJson = (res.data?['jobs'] as List?) ?? const [];
    final rootJobs = rootJobsJson
        .whereType<Map<String, dynamic>>()
        .map((j) => JenkinsNode.fromJson(j))
        .toList(growable: false);

    final viewsJson = (res.data?['views'] as List?) ?? const [];
    final viewFolders = <JenkinsNode>[];
    for (final v in viewsJson.whereType<Map<String, dynamic>>()) {
      final viewName = (v['name'] as String?)?.trim() ?? '';
      if (viewName.isEmpty || _isJenkinsAllViewName(viewName)) continue;
      final viewJobsJson = (v['jobs'] as List?) ?? const [];
      final children = viewJobsJson
          .whereType<Map<String, dynamic>>()
          .map((j) => JenkinsNode.fromJson(j))
          .toList(growable: false);
      if (children.isEmpty) continue;
      viewFolders.add(
        JenkinsNode(
          name: viewName,
          fullName: '$kJenkinsSyntheticViewFullNamePrefix$viewName',
          url: (v['url'] as String?) ?? '',
          kind: JenkinsNodeKind.folder,
          color: null,
          children: children,
        ),
      );
    }

    if (viewFolders.isEmpty) return rootJobs;

    viewFolders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final inViews = _collectFullNamesUnderViewFolders(viewFolders);
    final filteredRoots = _filterRootJobsDuplicatedInViews(rootJobs, inViews);
    return [...viewFolders, ...filteredRoots];
  }

  /// 拉取单个 job 详情。
  ///
  /// 若默认 JSON 未带上参数定义（常见于省略 lazy actions），再请求一次带 `tree` 的补充字段。
  Future<Map<String, dynamic>> fetchJobDetail(String fullName) async {
    final path = _jobApiPath(fullName);
    final res = await _dio.get<Map<String, dynamic>>(path);
    var data = res.data ?? const <String, dynamic>{};
    if (parseParameters(data).isEmpty) {
      final narrow = await _fetchJobParameterSlice(fullName);
      data = _mergeJobParameterFields(data, narrow);
    }
    return data;
  }

  /// 仅请求可能包含 [parameterDefinitions] 的字段（减小体积）。
  Future<Map<String, dynamic>> _fetchJobParameterSlice(String fullName) async {
    final path = _jobApiPath(fullName);
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: {
          'tree':
              'property[parameterDefinitions[name,type,description,defaultParameterValue[value],choices]],'
              'actions[parameterDefinitions[name,type,description,defaultParameterValue[value],choices]]',
        },
      );
      return res.data ?? const {};
    } catch (_) {
      return const {};
    }
  }

  Map<String, dynamic> _mergeJobParameterFields(
    Map<String, dynamic> full,
    Map<String, dynamic> narrow,
  ) {
    if (narrow.isEmpty) return full;
    final merged = Map<String, dynamic>.from(full);
    if (narrow['property'] != null) merged['property'] = narrow['property'];
    if (narrow['actions'] != null) merged['actions'] = narrow['actions'];
    return merged;
  }

  /// 解析 [fetchJobDetail] 的结果，得到参数定义。
  ///
  /// Jenkins 常见两种来源：
  /// - `actions[]` 中含 `parameterDefinitions`（旧 UI / 部分插件）
  /// - `property[]` 中 `hudson.model.ParametersDefinitionProperty`（Pipeline / 新版默认）
  List<BuildParameter> parseParameters(Map<String, dynamic> jobJson) {
    final fromActions = _parameterDefinitionsFromActionLike(jobJson['actions']);
    if (fromActions.isNotEmpty) return fromActions;

    final fromProperty = _parameterDefinitionsFromProperty(jobJson['property']);
    if (fromProperty.isNotEmpty) return fromProperty;

    return _deepFindParameterDefinitions(jobJson);
  }

  List<BuildParameter> _parameterDefinitionsFromActionLike(dynamic actions) {
    if (actions is! List) return const [];
    for (final a in actions) {
      if (a is! Map<String, dynamic>) continue;
      final defs = a['parameterDefinitions'];
      if (defs is List && defs.isNotEmpty) {
        return defs
            .whereType<Map<String, dynamic>>()
            .map(BuildParameter.fromJson)
            .toList(growable: false);
      }
    }
    return const [];
  }

  List<BuildParameter> _parameterDefinitionsFromProperty(dynamic property) {
    if (property is! List) return const [];
    final out = <BuildParameter>[];
    for (final p in property) {
      if (p is! Map<String, dynamic>) continue;
      final defs = p['parameterDefinitions'];
      if (defs is! List || defs.isEmpty) continue;
      out.addAll(
        defs.whereType<Map<String, dynamic>>().map(BuildParameter.fromJson),
      );
    }
    return out;
  }

  /// 兜底：某些插件把参数嵌在意外层级。
  List<BuildParameter> _deepFindParameterDefinitions(
    Map<String, dynamic> root, [
    int depth = 0,
  ]) {
    if (depth > 8) return const [];
    final defs = root['parameterDefinitions'];
    if (defs is List && defs.isNotEmpty) {
      return defs
          .whereType<Map<String, dynamic>>()
          .map(BuildParameter.fromJson)
          .toList(growable: false);
    }
    for (final value in root.values) {
      if (value is Map<String, dynamic>) {
        final found = _deepFindParameterDefinitions(value, depth + 1);
        if (found.isNotEmpty) return found;
      } else if (value is List) {
        for (final item in value) {
          if (item is Map<String, dynamic>) {
            final found = _deepFindParameterDefinitions(item, depth + 1);
            if (found.isNotEmpty) return found;
          }
        }
      }
    }
    return const [];
  }

  /// 拉取构建详情。
  Future<JenkinsBuild> fetchBuild(String jobFullName, int buildNumber) async {
    final path = '${_jobApiPath(jobFullName, withApi: false)}/$buildNumber/api/json';
    final res = await _dio.get<Map<String, dynamic>>(path);
    return JenkinsBuild.fromJson(res.data ?? const {});
  }

  /// 调用 Git Parameter 插件的 `fillValueItems` 接口，获取远端所有分支/Tag 列表。
  ///
  /// 该接口由 `net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition`
  /// 提供，Jenkins 使用 Job 自身配置的 SCM 凭证直接查询远端，无需本地 git。
  /// 若 Job 未使用 Git Parameter 插件或权限不足，请求会 4xx，返回空列表。
  ///
  /// 返回里同时带 [RefType]：插件给的 `value` / `name` 含 `refs/tags/`、`tags/`、
  /// `origin/`、`[Tag]`/`[Branch]` 等线索时能精确判定；否则回退到字面启发式。
  Future<List<RefOption>> fetchGitParameterValues(
    String jobFullName,
    String paramName,
  ) async {
    final base = _jobApiPath(jobFullName, withApi: false);
    const descriptor =
        'net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition';
    final path = '$base/descriptorByName/$descriptor/fillValueItems';
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: {'param': paramName},
      );
      final data = res.data;
      if (data == null) return const [];
      final values = data['values'];
      if (values is! List) return const [];
      return values
          .whereType<Map<String, dynamic>>()
          .map((e) {
            final value = (e['value'] as String?) ?? '';
            final name = e['name'] as String?;
            return RefOption(value, detectRefType(value, pluginName: name));
          })
          .where((o) => o.value.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 收集 Job 历史构建里**指定参数**用过的值（按"最近一次出现"为先去重）。
  ///
  /// 用途：在表单里把「git 分支」类参数渲染为可下拉/搜索的输入框。
  /// Jenkins 没有"列出仓库分支"的标准 REST 接口，但 `actions[].parameters[]`
  /// 在每条 build 上都会回放本次提交的参数值，足以反推出大概率仍然有效的分支名集合。
  ///
  /// - 失败一律降级为空列表（调用方会把它当作"没有候选"，输入框照常工作）。
  /// - [count] 控制扫描多少条历史；默认 50 条对绝大多数项目已足够稳定。
  Future<List<RefOption>> fetchHistoricalParameterValues(
    String jobFullName,
    String paramName, {
    int count = 50,
  }) async {
    final path = _jobApiPath(jobFullName);
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: {
          'tree': 'builds[actions[parameters[name,value]]]{0,$count}',
        },
      );
      final builds = (res.data?['builds'] as List?) ?? const [];
      // 用 LinkedHashSet 保持"最近 build → 最近的值"靠前；
      // 同一分支多次出现只算一次。
      final seen = <String>{};
      final ordered = <RefOption>[];
      for (final b in builds) {
        if (b is! Map<String, dynamic>) continue;
        final actions = b['actions'];
        if (actions is! List) continue;
        for (final a in actions) {
          if (a is! Map<String, dynamic>) continue;
          final params = a['parameters'];
          if (params is! List) continue;
          for (final p in params) {
            if (p is! Map<String, dynamic>) continue;
            if (p['name'] != paramName) continue;
            final v = p['value'];
            if (v == null) continue;
            final s = v.toString();
            if (s.isEmpty) continue;
            if (seen.add(s)) ordered.add(RefOption(s, detectRefType(s)));
          }
        }
      }
      return ordered;
    } catch (_) {
      return const [];
    }
  }

  /// 拉取构建历史（最近 [count] 个）。
  Future<List<JenkinsBuild>> fetchBuildHistory(String jobFullName, {int count = 20}) async {
    final path = _jobApiPath(jobFullName);
    final res = await _dio.get<Map<String, dynamic>>(path, queryParameters: {
      'tree':
          'builds[number,url,result,timestamp,duration,estimatedDuration,building,displayName,fullDisplayName]{0,$count}',
    });
    final builds = (res.data?['builds'] as List?) ?? const [];
    return builds
        .whereType<Map<String, dynamic>>()
        .map(JenkinsBuild.fromJson)
        .toList(growable: false);
  }

  /// 构建历史 + 每次构建的参数快照（用于「历史发版记录」）。
  Future<List<JenkinsReleaseHistoryRow>> fetchReleaseHistory(
    String jobFullName, {
    int count = 40,
  }) async {
    final path = _jobApiPath(jobFullName);
    final res = await _dio.get<Map<String, dynamic>>(path, queryParameters: {
      'tree':
          'builds['
          'number,url,result,timestamp,duration,estimatedDuration,building,displayName,fullDisplayName,'
          'changeSet[items[commitId]],changeSets[items[commitId]],'
          'actions[parameters[name,value],causes[userId,userName,shortDescription,_class],lastBuiltRevision[SHA1]]'
          ']{0,$count}',
    });
    final builds = (res.data?['builds'] as List?) ?? const [];
    return builds
        .whereType<Map<String, dynamic>>()
        .map(
          (raw) => JenkinsReleaseHistoryRow(
            build: JenkinsBuild.fromJson(raw),
            parameters: _parameterMapFromBuildActions(raw),
            releasedBy: _releasedByFromBuildJson(raw),
            gitRevision: _gitRevisionFromBuildJson(raw),
          ),
        )
        .toList(growable: false);
  }

  /// Jenkins `UserIdCause` 等在 `actions[].causes[]` 中。
  String? _releasedByFromBuildJson(Map<String, dynamic> raw) {
    final actions = raw['actions'];
    if (actions is! List) return null;
    for (final a in actions) {
      if (a is! Map<String, dynamic>) continue;
      final causes = a['causes'];
      if (causes is! List) continue;
      for (final c in causes) {
        if (c is! Map<String, dynamic>) continue;
        final cls = (c['_class'] as String?) ?? '';
        final userName = (c['userName'] as String?)?.trim();
        if (userName != null && userName.isNotEmpty) return userName;
        final userId = (c['userId'] as String?)?.trim();
        if (userId != null && userId.isNotEmpty) return userId;
        if (!cls.contains('UserIdCause')) continue;
        final sd = (c['shortDescription'] as String?)?.trim();
        if (sd != null && sd.isNotEmpty) {
          final m = RegExp(r'Started by user\s+(.+?)\s*$', caseSensitive: false).firstMatch(sd);
          if (m != null) {
            final u = m.group(1)?.trim();
            if (u != null && u.isNotEmpty) return u;
          }
          return sd;
        }
      }
    }
    return null;
  }

  /// Git 插件 `BuildData.lastBuiltRevision.SHA1`，或 `changeSet(s)` 首条 `commitId`。
  String? _gitRevisionFromBuildJson(Map<String, dynamic> raw) {
    final actions = raw['actions'];
    if (actions is List) {
      for (final a in actions) {
        if (a is! Map<String, dynamic>) continue;
        final built = a['lastBuiltRevision'];
        if (built is Map<String, dynamic>) {
          final sha = (built['SHA1'] as String?)?.trim();
          if (sha != null && sha.isNotEmpty) return sha;
        }
      }
    }
    String? fromItems(dynamic items) {
      if (items is! List || items.isEmpty) return null;
      final first = items.first;
      if (first is! Map<String, dynamic>) return null;
      for (final key in ['commitId', 'commitID']) {
        final v = first[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final cs = raw['changeSet'];
    if (cs is Map<String, dynamic>) {
      final id = fromItems(cs['items']);
      if (id != null) return id;
    }
    final css = raw['changeSets'];
    if (css is List) {
      for (final block in css) {
        if (block is! Map<String, dynamic>) continue;
        final id = fromItems(block['items']);
        if (id != null) return id;
      }
    }
    return null;
  }

  Map<String, String> _parameterMapFromBuildActions(Map<String, dynamic> buildJson) {
    final out = <String, String>{};
    final actions = buildJson['actions'];
    if (actions is! List) return out;
    for (final a in actions) {
      if (a is! Map<String, dynamic>) continue;
      final params = a['parameters'];
      if (params is! List) continue;
      for (final p in params) {
        if (p is! Map<String, dynamic>) continue;
        final name = (p['name'] as String?)?.trim();
        if (name == null || name.isEmpty) continue;
        final v = p['value'];
        out[name] = v?.toString() ?? '';
      }
    }
    return out;
  }

  /// 增量拉取控制台日志：返回 (text, hasMore, nextStart)
  Future<({String text, bool hasMore, int nextStart})> fetchProgressiveLog(
    String jobFullName,
    int buildNumber, {
    int start = 0,
  }) async {
    final path = '${_jobApiPath(jobFullName, withApi: false)}/$buildNumber/logText/progressiveText';
    final res = await _dio.get<String>(
      path,
      queryParameters: {'start': start},
      options: Options(responseType: ResponseType.plain),
    );
    final hasMore = res.headers.value('x-more-data') == 'true';
    final nextStart = int.tryParse(res.headers.value('x-text-size') ?? '') ?? start;
    return (text: res.data ?? '', hasMore: hasMore, nextStart: nextStart);
  }

  /// 拉取 Pipeline 阶段（依赖 Pipeline Stage View Plugin）。失败时返回空列表。
  Future<List<BuildStage>> fetchStages(String jobFullName, int buildNumber) async {
    final path = '${_jobApiPath(jobFullName, withApi: false)}/$buildNumber/wfapi/describe';
    try {
      final res = await _dio.get<Map<String, dynamic>>(path);
      if (res.statusCode != 200) return const [];
      final stages = (res.data?['stages'] as List?) ?? const [];
      return stages
          .whereType<Map<String, dynamic>>()
          .map(BuildStage.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// 触发构建。
  ///
  /// - 若 [parameters] 非空，使用 `/buildWithParameters`；
  /// - 否则使用 `/build`。
  ///
  /// 说明：
  /// - 不少 Jenkins（尤其开启 CSRF）要求 **application/x-www-form-urlencoded 请求体**
  ///   携带参数，仅用 URL query 会返回 **403**。
  /// - **Pipeline / WorkflowJob** 在部分实例上对 `buildWithParameters` 返回 **400**，需改用
  ///   `POST .../build`，表单字段 **`json={"parameter":[{"name":...,"value":...}]}`**（官方 Remote API 用法）。
  ///
  /// 返回队列项 URL（形如 `https://.../queue/item/12345/`），可用 [pollQueueItem]
  /// 等待 build 启动并取得 build number。
  Future<String> triggerBuild(
    String jobFullName, {
    Map<String, String> parameters = const {},
    String? jobClass,
  }) async {
    var start = _successStrategy[jobFullName] ?? 0;
    // 已知是 Pipeline / Workflow Job 时直接跳到 `POST /build` + json= 策略；
    // 否则 buildWithParameters 一定会 400，纯属浪费。
    if (start == 0 && parameters.isNotEmpty && jobClass != null && _isPipelineJob(jobClass)) {
      start = 4;
    }
    return _triggerBuildWithRetries(jobFullName, parameters, attempt: start);
  }

  static bool _isPipelineJob(String cls) {
    final lower = cls.toLowerCase();
    return lower.contains('workflowjob') ||
        lower.contains('workflowmultibranchproject') ||
        lower.contains('workflowscript');
  }

  /// 终止指定运行中的 build。
  ///
  /// Jenkins 暴露三个终止接口（强度递增）：
  ///   - `/stop`：礼貌停止，触发流水线 `aborted` 流程；多数情况首选；
  ///   - `/term`：在 `/stop` 卡住时升级；
  ///   - `/kill`：最后手段，可能留下脏状态。
  ///
  /// 这里默认尝试 `/stop`，若返回 4xx 再升级到 `/term`。所有请求都带 CSRF crumb +
  /// Referer，与 [triggerBuild] 一致。
  Future<void> stopBuild(String jobFullName, int buildNumber) async {
    final base = '${_jobApiPath(jobFullName, withApi: false)}/$buildNumber';

    Future<Options> buildOptions() async {
      final crumb = await _fetchCrumb();
      return Options(
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
        responseType: ResponseType.plain,
        headers: <String, dynamic>{
          if (crumb != null) crumb.field: crumb.value,
          'Referer': _jobPageReferer(jobFullName),
        },
      );
    }

    Future<int> postOnce(String suffix) async {
      try {
        final res = await _dio.post<dynamic>(
          '$base/$suffix',
          options: await buildOptions(),
        );
        return res.statusCode ?? 0;
      } on DioException catch (e) {
        throw toJenkinsException(e);
      }
    }

    // 先试 /stop。Jenkins 老版本 / 部分代理可能用 GET 才认（同时支持 POST），
    // 我们坚持 POST + crumb，能正常工作的实例占绝大多数。
    final stopCode = await postOnce('stop');
    if (stopCode == 200 || stopCode == 201 || stopCode == 302 || stopCode == 303) return;
    if (stopCode == 403 || stopCode == 401) {
      // session 可能 idle 失效，清掉 crumb+cookie 后用全新 header 再试一次
      await _clearSession();
      final retried = await postOnce('stop');
      if (retried == 200 || retried == 201 || retried == 302 || retried == 303) return;
    }
    // /stop 仍然失败 → 升级 /term
    final termCode = await postOnce('term');
    if (termCode == 200 || termCode == 201 || termCode == 302 || termCode == 303) return;

    throw JenkinsException(
      message: '终止构建失败（HTTP $stopCode → /term HTTP $termCode）。'
          '请确认账号有 Cancel 权限，或在 Jenkins 页面手动终止。',
      statusCode: termCode == 0 ? stopCode : termCode,
    );
  }

  Future<String> _triggerBuildWithRetries(
    String jobFullName,
    Map<String, String> parameters, {
    int attempt = 0,
    bool sessionRefreshed = false,
  }) async {
    final hasParams = parameters.isNotEmpty;
    final maxAttempts = hasParams ? 6 : 4;

    if (attempt >= maxAttempts) {
      throw JenkinsException(
        message:
            '触发构建失败：已尝试多种方式（buildWithParameters、Pipeline json=/build 等）仍被拒绝。'
            '请确认账号/API Token 有 Build 权限；反向代理是否剥离 Cookie 或 Jenkins-Crumb；'
            'Pipeline Job 参数名是否与 Jenkins 一致。',
      );
    }

    final base = _jobApiPath(jobFullName, withApi: false);

    final crumb = await _fetchCrumb();
    final headers = <String, dynamic>{
      if (crumb != null) crumb.field: crumb.value,
      'Referer': _jobPageReferer(jobFullName),
    };

    const delayQp = {'delay': '0sec'};

    final triggerOptions = Options(
      followRedirects: false,
      validateStatus: (s) => s != null && s < 500,
      responseType: ResponseType.plain,
    );

    late Response<dynamic> res;
    try {
      if (hasParams) {
        res = await _postParameterizedTrigger(
          base: base,
          parameters: parameters,
          strategy: attempt,
          crumb: crumb,
          headers: headers,
          delayQp: delayQp,
          triggerOptions: triggerOptions,
        );
      } else {
        res = await _postPlainTrigger(
          base: base,
          strategy: attempt,
          crumb: crumb,
          headers: headers,
          delayQp: delayQp,
          triggerOptions: triggerOptions,
        );
      }
    } on DioException catch (e) {
      throw toJenkinsException(e);
    }

    final code = res.statusCode ?? 0;
    if (code == 403 || code == 401) {
      // 第一次 403：很可能是 idle 后 session 失效。清掉 crumb+cookie，**同 strategy** 再试
      // 一次；否则一上来就推进 strategy，正常 Job 会被误推到 Pipeline json 路径。
      if (!sessionRefreshed) {
        await _clearSession();
        return _triggerBuildWithRetries(
          jobFullName,
          parameters,
          attempt: attempt,
          sessionRefreshed: true,
        );
      }
      // 刷新过仍 403 → 真正的策略不匹配 / 权限问题，再推进策略试下一种
      return _triggerBuildWithRetries(
        jobFullName,
        parameters,
        attempt: attempt + 1,
        sessionRefreshed: true,
      );
    }
    // buildWithParameters 在部分 Pipeline 上会 **400**，换 json=/build 后再试
    if (code == 400) {
      return _triggerBuildWithRetries(
        jobFullName,
        parameters,
        attempt: attempt + 1,
        sessionRefreshed: sessionRefreshed,
      );
    }
    if (code >= 400) {
      final raw = res.data;
      final bodyStr = raw is String ? raw : raw?.toString();
      throw JenkinsException(
        message: '触发构建失败（HTTP $code）',
        statusCode: code,
        body: bodyStr,
      );
    }

    final loc = res.headers.value('location');
    if (loc == null || loc.isEmpty) {
      throw JenkinsException(
        message: '触发构建成功但未返回队列地址（HTTP $code）',
        statusCode: code,
        body: res.data is String ? res.data as String : null,
      );
    }
    // 命中：记下策略编号，同 Job 下次直接复用，避免再来一遍 400 探测
    _successStrategy[jobFullName] = attempt;
    return loc;
  }

  /// Pipeline 远程触发：`json` 字段为 JSON 字符串。
  String _pipelineParametersJson(Map<String, String> parameters) {
    final list = parameters.entries.map((e) => {'name': e.key, 'value': e.value}).toList();
    return jsonEncode({'parameter': list});
  }

  Future<Response<dynamic>> _postParameterizedTrigger({
    required String base,
    required Map<String, String> parameters,
    required int strategy,
    required ({String field, String value})? crumb,
    required Map<String, dynamic> headers,
    required Map<String, dynamic> delayQp,
    required Options triggerOptions,
  }) async {
    final bw = '$base/buildWithParameters';
    final bb = '$base/build';
    final form = triggerOptions.copyWith(
      contentType: Headers.formUrlEncodedContentType,
      headers: headers,
    );

    switch (strategy) {
      case 0:
        final body = Map<String, String>.from(parameters);
        if (crumb != null) body.putIfAbsent(crumb.field, () => crumb.value);
        return _dio.post<dynamic>(bw, data: body, queryParameters: delayQp, options: form);
      case 1:
        final qp = <String, dynamic>{
          ...parameters,
          ...delayQp,
          if (crumb != null) crumb.field: crumb.value,
        };
        return _dio.post<dynamic>(bw, queryParameters: qp, options: form);
      case 2:
        return _dio.post<dynamic>(
          bw,
          data: Map<String, String>.from(parameters),
          queryParameters: delayQp,
          options: form,
        );
      case 3:
        return _dio.post<dynamic>(
          bw,
          queryParameters: <String, dynamic>{...parameters, ...delayQp},
          options: form,
        );
      case 4:
        final payload = _pipelineParametersJson(parameters);
        final body = <String, String>{
          'json': payload,
          if (crumb != null) crumb.field: crumb.value,
        };
        return _dio.post<dynamic>(bb, data: body, queryParameters: delayQp, options: form);
      case 5:
        final body = <String, String>{'json': _pipelineParametersJson(parameters)};
        return _dio.post<dynamic>(
          bb,
          data: body,
          queryParameters: delayQp,
          options: form.copyWith(headers: headers),
        );
      default:
        return _dio.post<dynamic>(
          bw,
          data: Map<String, String>.from(parameters),
          queryParameters: delayQp,
          options: form,
        );
    }
  }

  Future<Response<dynamic>> _postPlainTrigger({
    required String base,
    required int strategy,
    required ({String field, String value})? crumb,
    required Map<String, dynamic> headers,
    required Map<String, dynamic> delayQp,
    required Options triggerOptions,
  }) async {
    final bb = '$base/build';
    final form = triggerOptions.copyWith(
      contentType: Headers.formUrlEncodedContentType,
      headers: headers,
    );

    final crumbBody = strategy.isEven;
    if (crumbBody && crumb != null) {
      return _dio.post<dynamic>(
        bb,
        queryParameters: delayQp,
        data: {crumb.field: crumb.value},
        options: form,
      );
    }
    return _dio.post<dynamic>(
      bb,
      queryParameters: delayQp,
      options: triggerOptions.copyWith(headers: headers),
    );
  }

  /// 单次拉取队列项当前状态（含 why / cancelled / executable）。
  ///
  /// `queueUrl` 通常是 Jenkins 触发构建后 `Location` 头返回的绝对 URL，
  /// 形如 `https://.../queue/item/12345/`。
  Future<QueueItem?> fetchQueueItem(String queueUrl) async {
    final apiUrl = queueUrl.endsWith('/') ? '${queueUrl}api/json' : '$queueUrl/api/json';
    final res = await _dio.get<Map<String, dynamic>>(apiUrl);
    if (res.statusCode != 200 || res.data == null) return null;
    return QueueItem.fromJson(res.data!);
  }

  /// 轮询队列项直到拿到 build number 或被取消；超时返回 null。
  ///
  /// 仅作为兼容保留 — 推荐由上层 `ReleaseController` 用 [fetchQueueItem] 自行调度，
  /// 这样可以将 `why`（队列等待原因）实时回传 UI。
  Future<QueueItem?> pollQueueItem(
    String queueUrl, {
    Duration timeout = const Duration(minutes: 10),
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final item = await fetchQueueItem(queueUrl);
      if (item != null && (item.isStarted || item.cancelled)) return item;
      await Future<void>.delayed(interval);
    }
    return null;
  }

  // ---------- 内部 ----------

  /// 获取 Jenkins CSRF crumb（带 TTL 缓存）。
  ///
  /// 很多 Jenkins 开启了 CSRF Protection，所有 POST（包括 build/buildWithParameters）
  /// 都必须带 crumb header，否则会返回 403，看起来像“没有权限”。
  /// 旧 Jenkins / 关闭 CSRF 的环境可能没有该接口，失败时返回 null。
  Future<({String field, String value})?> _fetchCrumb() async {
    final cached = _crumb;
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _crumbTtl) {
      return (field: cached.field, value: cached.value);
    }
    try {
      final res = await _dio.get<Map<String, dynamic>>('/crumbIssuer/api/json');
      if (res.statusCode != 200 || res.data == null) {
        _crumb = null;
        return null;
      }
      final field = res.data!['crumbRequestField'] as String?;
      final value = res.data!['crumb'] as String?;
      if (field == null || field.isEmpty || value == null || value.isEmpty) {
        _crumb = null;
        return null;
      }
      _crumb = _CrumbCache(field, value, DateTime.now());
      return (field: field, value: value);
    } catch (_) {
      return null;
    }
  }

  /// 同时清掉 crumb 和会话 cookie。
  ///
  /// 单清 crumb 不够：CookieManager 仍会把旧 `JSESSIONID` 带在下一次请求上，
  /// 服务端拿到 "新 crumb + 旧 session" 仍会判定不匹配并继续 403。
  Future<void> _clearSession() async {
    _crumb = null;
    final jar = jenkinsCookieJarOf(_dio);
    if (jar != null) await jar.deleteAll();
  }

  /// Job 控制台页 URL，用作 `Referer`（需与 Jenkins 站点同源）。
  String _jobPageReferer(String jobFullName) {
    final root = _dio.options.baseUrl;
    if (root.isEmpty) return root;
    final jobPath = _jobApiPath(jobFullName, withApi: false);
    final origin = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    return '$origin$jobPath/';
  }

  /// 把 `backend/order-service` 转成 `/job/backend/job/order-service/api/json`
  String _jobApiPath(String fullName, {bool withApi = true}) {
    final segments = fullName.split('/').where((s) => s.isNotEmpty);
    final path = segments.map((s) => '/job/${Uri.encodeComponent(s)}').join();
    return withApi ? '$path/api/json' : path;
  }

  String _treeQuery(int depth) {
    String build(int d) {
      if (d <= 0) return 'jobs[name,url,_class,color,buildable]';
      return 'jobs[name,url,_class,color,buildable,${build(d - 1)}]';
    }

    return build(depth);
  }
}

class _CrumbCache {
  _CrumbCache(this.field, this.value, this.fetchedAt);

  final String field;
  final String value;
  final DateTime fetchedAt;
}

bool _isJenkinsAllViewName(String name) => name.toLowerCase() == 'all';

void _addSubtreeFullNames(JenkinsNode n, Set<String> sink) {
  sink.add(n.fullName);
  for (final c in n.children) {
    _addSubtreeFullNames(c, sink);
  }
}

Set<String> _collectFullNamesUnderViewFolders(List<JenkinsNode> viewFolders) {
  final set = <String>{};
  for (final folder in viewFolders) {
    for (final child in folder.children) {
      _addSubtreeFullNames(child, set);
    }
  }
  return set;
}

JenkinsNode? _pruneIfInViewSet(JenkinsNode n, Set<String> inViews) {
  if (inViews.contains(n.fullName)) return null;
  if (n.children.isEmpty) return n;
  final next = <JenkinsNode>[];
  for (final c in n.children) {
    final kept = _pruneIfInViewSet(c, inViews);
    if (kept != null) next.add(kept);
  }
  if (next.isEmpty) return null;
  return n.copyWith(children: next);
}

List<JenkinsNode> _filterRootJobsDuplicatedInViews(
  List<JenkinsNode> roots,
  Set<String> inViews,
) {
  return roots.map((r) => _pruneIfInViewSet(r, inViews)).whereType<JenkinsNode>().toList();
}
