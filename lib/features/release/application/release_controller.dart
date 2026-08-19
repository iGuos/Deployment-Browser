import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/locale/app_locale_controller.dart';
import '../../../core/notifications/build_notifier.dart';
import '../../../core/notifications/notifications_settings.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../../jenkins/domain/jenkins_build.dart';
import '../../notifications/slack/slack_notifier.dart';

/// 一次"运行实例"的标识。
///
/// - [jenkinsAccountId]：本地多账号工作区中的账号 id，用于绑定正确的 Jenkins API。
/// - [jobFullName]：Jenkins Job 全名（含目录前缀）。
/// - [runId]：本次点击「立即构建」时 UI 侧生成的唯一 id，用于把同一 Job 的
///   不同次构建区分成相互独立的 [ReleaseController] 实例（→ 右侧多 tab）。
typedef RunHandle = ({
  String jenkinsAccountId,
  String jobFullName,
  String runId,
});

typedef ProjectRunTabsKey = ({String accountId, String fullName});

@immutable
class ProjectRunTabsState {
  const ProjectRunTabsState({
    this.runs = const [],
    this.activeIndex = 0,
    this.nextSeq = 0,
  });

  final List<RunHandle> runs;
  final int activeIndex;
  final int nextSeq;

  RunHandle? get activeRun =>
      runs.isEmpty ? null : runs[activeIndex.clamp(0, runs.length - 1)];

  ProjectRunTabsState copyWith({
    List<RunHandle>? runs,
    int? activeIndex,
    int? nextSeq,
  }) {
    return ProjectRunTabsState(
      runs: runs ?? this.runs,
      activeIndex: activeIndex ?? this.activeIndex,
      nextSeq: nextSeq ?? this.nextSeq,
    );
  }
}

class ProjectRunTabsController extends Notifier<ProjectRunTabsState> {
  ProjectRunTabsController(this.key);

  final ProjectRunTabsKey key;

  @override
  ProjectRunTabsState build() => const ProjectRunTabsState();

  RunHandle addRun(String jobFullName) {
    final nextSeq = state.nextSeq + 1;
    final handle = (
      jenkinsAccountId: key.accountId,
      jobFullName: jobFullName,
      runId: '${DateTime.now().millisecondsSinceEpoch}-$nextSeq',
    );
    final runs = [...state.runs, handle];
    state = state.copyWith(
      runs: runs,
      activeIndex: runs.length - 1,
      nextSeq: nextSeq,
    );
    return handle;
  }

  void selectRun(int index) {
    if (index < 0 || index >= state.runs.length) return;
    state = state.copyWith(activeIndex: index);
  }

  void closeRun(int index) {
    if (index < 0 || index >= state.runs.length) return;
    final handle = state.runs[index];
    final runs = [...state.runs]..removeAt(index);
    var activeIndex = state.activeIndex;
    if (runs.isEmpty) {
      activeIndex = 0;
    } else if (activeIndex >= runs.length) {
      activeIndex = runs.length - 1;
    } else if (activeIndex > index) {
      activeIndex -= 1;
    }
    state = state.copyWith(runs: runs, activeIndex: activeIndex);
    ref.invalidate(releaseControllerProvider(handle));
  }

  void disposeRuns() {
    for (final handle in state.runs) {
      ref.invalidate(releaseControllerProvider(handle));
    }
    state = const ProjectRunTabsState();
  }
}

/// 进程内的"build 号占位"注册表。
///
/// 解决多 tab 并发触发时的竞态：用户在 1~2 秒内连续点两次「立即构建」，
/// Jenkins 那一头几乎同时建立两个队列项（如 #35、#36），但两次 trigger 内部
/// 拉 history 时常常只看到旧的 #34（新建的还没刷出来），导致两个 controller
/// 都把"必须严格大于 #34 的最早一条"匹配到 #35，从而**同时附着到同一条 build**。
///
/// [reserve] 在同步代码段内自增"已被占用的最大 build 号"并返回新值，让每次
/// trigger 都拿到独一无二的下界，互不冲突。
class ReservedBuildNumberRegistry {
  final Map<String, int> _reserved = {};

  /// 在 [floor]（通常来自 fetchHistory 的最新 build 号）之上原子地占用一个号，
  /// 返回的整数即为本次 trigger 的"必须严格 ≥"下界。
  int reserve(String jobFullName, int floor) {
    final current = _reserved[jobFullName] ?? 0;
    final ceiling = math.max(current, floor);
    final next = ceiling + 1;
    _reserved[jobFullName] = next;
    return next;
  }

  /// 仅用于单测重置，避免相互污染。
  @visibleForTesting
  void clear() => _reserved.clear();
}

final reservedBuildNumberRegistryProvider =
    Provider<ReservedBuildNumberRegistry>((_) => ReservedBuildNumberRegistry());

/// 单个项目当前活跃的发版任务状态。
@immutable
class ReleaseRunState {
  const ReleaseRunState({
    required this.jobFullName,
    this.queueUrl,
    this.queueItemId,
    this.queueWhy,
    this.queueWaitedSeconds = 0,
    this.queueTriggeredAt,
    this.buildNumber,
    this.build,
    this.stages = const [],
    this.stageLayoutTemplate = const [],
    this.errorMessage,
    this.triggering = false,
    this.aborting = false,
    this.slackRecipients = const [],
    this.variantLabel,
  });

  final String jobFullName;
  final String? queueUrl;
  final int? queueItemId;

  /// Jenkins 队列接口返回的「为何还在等待」描述
  /// （如：`Waiting for next available executor`）。
  final String? queueWhy;
  final int queueWaitedSeconds;

  /// 触发本次构建的客户端本地时间（毫秒），用于在 queue 项失效后通过
  /// 构建历史 + timestamp 反向找回真实 build number。
  final int? queueTriggeredAt;

  final int? buildNumber;
  final JenkinsBuild? build;
  final List<BuildStage> stages;

  /// 来自 **上一构建**（通常为 `buildNumber - 1`）的 `wfapi/describe` 阶段列表，
  /// 仅用于运行中 UI：与 [stages] 合并后可一次展示全部阶段名，再随当前构建进度逐段更新。
  final List<BuildStage> stageLayoutTemplate;

  final String? errorMessage;
  final bool triggering;

  /// 正在向 Jenkins 发送终止请求；用于禁用「终止」按钮，避免重复点。
  final bool aborting;

  /// 本次构建选定的 Slack 通知人；用于在进度面板表头展示「本次构建完通知谁」。
  final List<SlackRecipient> slackRecipients;

  /// 区分「同一次点击展开出的多个 run」的短标签（多选参数的取值，如 `admin-api`）。
  /// 单选触发为 null。仅用于 UI / 通知展示，不参与任何 Jenkins 请求。
  final String? variantLabel;

  /// 是否正在等待 Jenkins 把这次触发派发到执行器。
  ///
  /// 注意：不能仅以 `queueUrl != null` 判断，因为部分 Jenkins / 反代触发后返回的
  /// `Location` 不是 `/queue/item/` 队列地址；那时我们退化到「按 triggeredAt 查 build
  /// history」模式，`queueUrl` 可能是 null 但本质上仍处于等待状态。
  bool get hasQueueWaiting => queueTriggeredAt != null;
  bool get isRunning => build?.building == true;
  bool get hasResult => build != null && build!.building == false;

  /// 进度面板用：构建进行中且已拿到上一跑模板时合并展示；否则用实时 [stages]。
  List<BuildStage> get stagesForProgressDisplay {
    final b = build;
    if (b == null) return stages;
    if (!b.building || stageLayoutTemplate.isEmpty) return stages;
    return mergeBuildStagesForRunning(stageLayoutTemplate, stages);
  }

  /// 基于阶段进度估算整体百分比；只在拿到上一跑模板时才有意义。
  ///
  /// Jenkins 的 `estimatedDuration` 是按耗时算的，本次跑比上次慢时进度条会
  /// 在前几个阶段就接近满格。改用「已完成阶段数 + 当前阶段在模板中的耗时占
  /// 比」可以更稳：完成多少格就显示多少格。
  ///
  /// 模板缺失或还没有任何阶段开始时返回 null，让调用方退回到时间估算。
  double? get progressByStages {
    final b = build;
    if (b == null || !b.building) return null;
    if (stageLayoutTemplate.isEmpty) return null;
    final merged = mergeBuildStagesForRunning(stageLayoutTemplate, stages);
    if (merged.isEmpty) return null;
    final total = merged.length;
    final templateByName = <String, BuildStage>{
      for (final s in stageLayoutTemplate) s.name: s,
    };
    double done = 0;
    for (final s in merged) {
      if (s.isSuccess || s.isFailed) {
        done += 1;
      } else if (s.isRunning) {
        final t = templateByName[s.name];
        final expected = (t?.durationMillis ?? 0);
        final frac = expected > 0
            ? (s.durationMillis / expected).clamp(0.0, 0.95)
            : 0.5;
        done += frac;
      }
    }
    return (done / total).clamp(0.0, 0.98);
  }

  ReleaseRunState copyWith({
    String? queueUrl,
    int? queueItemId,
    String? queueWhy,
    int? queueWaitedSeconds,
    int? queueTriggeredAt,
    int? buildNumber,
    JenkinsBuild? build,
    List<BuildStage>? stages,
    List<BuildStage>? stageLayoutTemplate,
    String? errorMessage,
    bool? triggering,
    bool? aborting,
    List<SlackRecipient>? slackRecipients,
    String? variantLabel,
    bool clearError = false,
    bool clearQueue = false,
    bool clearBuild = false,
    bool clearVariantLabel = false,
  }) {
    return ReleaseRunState(
      jobFullName: jobFullName,
      queueUrl: clearQueue ? null : (queueUrl ?? this.queueUrl),
      queueItemId: clearQueue ? null : (queueItemId ?? this.queueItemId),
      queueWhy: clearQueue ? null : (queueWhy ?? this.queueWhy),
      queueWaitedSeconds: clearQueue
          ? 0
          : (queueWaitedSeconds ?? this.queueWaitedSeconds),
      queueTriggeredAt: clearQueue
          ? null
          : (queueTriggeredAt ?? this.queueTriggeredAt),
      buildNumber: clearBuild ? null : (buildNumber ?? this.buildNumber),
      build: clearBuild ? null : (build ?? this.build),
      stages: clearBuild ? const [] : (stages ?? this.stages),
      stageLayoutTemplate: clearBuild
          ? const []
          : (stageLayoutTemplate ?? this.stageLayoutTemplate),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      triggering: triggering ?? this.triggering,
      aborting: aborting ?? this.aborting,
      slackRecipients: slackRecipients ?? this.slackRecipients,
      variantLabel: clearVariantLabel
          ? null
          : (variantLabel ?? this.variantLabel),
    );
  }
}

class ReleaseController extends Notifier<ReleaseRunState> {
  ReleaseController(this.handle);

  /// 本 controller 对应的运行实例（job + runId）。
  final RunHandle handle;

  /// 便捷访问：只需要 jobFullName 时不必每次解一遍 record。
  String get jobFullName => handle.jobFullName;

  String get _registryKey => '${handle.jenkinsAccountId}::$jobFullName';

  JenkinsRepository? _repo() =>
      ref.read(jenkinsRepositoryForAccountProvider(handle.jenkinsAccountId));

  /// 构建（已分配 executor 后）的轮询定时器
  Timer? _buildPollTimer;

  /// 队列 + history 兜底定位新构建的轮询定时器（在拿到 buildNumber 之前）
  Timer? _queuePollTimer;

  @override
  ReleaseRunState build() {
    ref.onDispose(_cancelTimers);
    return ReleaseRunState(jobFullName: jobFullName);
  }

  void _cancelTimers() {
    _buildPollTimer?.cancel();
    _buildPollTimer = null;
    _queuePollTimer?.cancel();
    _queuePollTimer = null;
  }

  /// 本次发版选定的 Slack 通知接收人（为空则不发 Slack）。
  List<SlackRecipient> _slackRecipients = const [];

  /// 通知里用来替代冗长 Job 全名的别名（为空则用 [jobFullName]）。
  String? _jobAlias;

  /// 通知中展示的项目名：有别名用别名，否则回退到 Job 全名。
  String get _notifyJobName {
    final base = (_jobAlias != null && _jobAlias!.trim().isNotEmpty)
        ? _jobAlias!.trim()
        : jobFullName;
    // 一次点击发出多路构建（多选参数）时，通知里必须带上是哪一路。
    final variant = state.variantLabel;
    if (variant == null || variant.isEmpty) return base;
    return '$base · $variant';
  }

  /// 触发一次新构建。
  ///
  /// 设计原则：**保留旧的 build / buildNumber / stages 仍可见**，只重置队列状态与错误。
  /// 等队列轮询拿到新的 build number 时才会替换旧的。这样在 Jenkins 还没分配 executor
  /// 之前，用户依旧能看到上一次构建的进度 / 结果。
  ///
  /// [slackRecipients]：本次构建结束时要私信的人（来自发版页选择）。
  Future<void> trigger({
    Map<String, String> parameters = const {},
    List<SlackRecipient> slackRecipients = const [],
    String? jobAlias,
    String? variantLabel,
  }) async {
    _slackRecipients = slackRecipients;
    _jobAlias = jobAlias;
    final repo = _repo();
    if (repo == null) return;
    _queuePollTimer?.cancel();
    _queuePollTimer = null;

    state = state.copyWith(
      triggering: true,
      clearError: true,
      clearQueue: true,
      slackRecipients: slackRecipients,
      // 单选触发（variantLabel == null）要把上一次的多选标签清掉，
      // 否则同一 run 被复用时 tab 上会挂着过期的取值。
      variantLabel: variantLabel,
      clearVariantLabel: variantLabel == null,
    );
    final triggeredAt = DateTime.now().millisecondsSinceEpoch;
    // 触发前先拉一次 history 记录当前最大 build 号；再叠加进程内的"已占用门槛"，
    // 取较大者 + 1 作为本次 run 的"必须 ≥ 此值"下界。这样：
    // - 单次触发：等到下一个新 build（>= floor + 1）；
    // - 短时连续触发：第二次的 floor 会被注册表推到第一次的 reserved 之上，
    //   再 + 1 得到独属于自己的下界，两个 tab 不会抢同一条 build。
    var historyFloor = state.buildNumber ?? 0;
    try {
      final history = await repo.fetchHistory(state.jobFullName, count: 1);
      if (history.isNotEmpty) {
        historyFloor = math.max(historyFloor, history.first.number);
      }
    } catch (_) {
      // 拉不到不致命，下面 reserve 仍能给出递增门槛
    }
    final reservedMin = ref
        .read(reservedBuildNumberRegistryProvider)
        .reserve(_registryKey, historyFloor);
    try {
      final returnedLocation = await repo.triggerBuild(
        state.jobFullName,
        parameters: parameters,
      );
      // 部分 Jenkins / 反代触发后 `Location` 不是 `/queue/item/{N}/` 而是 Job 主页 URL；
      // 此时按这个 URL 去 GET 永远拿不到 executable.number。
      // 我们用包含 `/queue/item/` 来识别合法 queue URL；不合法时只记录 triggeredAt，
      // 完全靠 build history + 时间戳兜底。
      final isProperQueueUrl = returnedLocation.contains('/queue/item/');
      state = state.copyWith(
        triggering: false,
        queueUrl: isProperQueueUrl ? returnedLocation : null,
        queueItemId: isProperQueueUrl
            ? _extractQueueId(returnedLocation)
            : null,
        queueWhy: null,
        queueWaitedSeconds: 0,
        queueTriggeredAt: triggeredAt,
      );
      _startQueuePolling(reservedMin: reservedMin);
    } catch (e) {
      state = state.copyWith(triggering: false, errorMessage: e.toString());
    }
  }

  /// 用户从历史选择某次构建查看
  Future<void> attachBuild(int number) async {
    _cancelTimers();
    state = state.copyWith(
      buildNumber: number,
      stages: const [],
      clearError: true,
      clearQueue: true,
      clearBuild: true,
    );
    state = state.copyWith(buildNumber: number);
    _startBuildPolling(number);
  }

  /// 用户主动放弃等待队列（不影响 Jenkins 那边的 build，
  /// 仅停止本地轮询，可在历史里再连回来）
  void cancelQueueWait() {
    _queuePollTimer?.cancel();
    _queuePollTimer = null;
    state = state.copyWith(clearQueue: true, clearError: true);
  }

  /// 向 Jenkins 发送终止请求，把当前运行中的 build 中止。
  ///
  /// 仅在 `state.build?.building == true` 时有意义；调用方（UI）应自行判断
  /// 是否禁用按钮。这里不主动 cancelTimers——服务端处理完成后下一次
  /// `_pollBuildOnce` 会读到 `result == ABORTED`，自然会停轮询。
  Future<void> abortBuild() async {
    final number = state.buildNumber;
    if (number == null) return;
    if (state.aborting) return;
    final repo = _repo();
    if (repo == null) return;
    state = state.copyWith(aborting: true, clearError: true);
    try {
      await repo.stopBuild(state.jobFullName, number);
      // 立刻轮询一次，让 UI 尽快感知到 ABORTED 状态
      await _pollBuildOnce(number);
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(aborting: false);
    }
  }

  void reset() {
    _cancelTimers();
    state = ReleaseRunState(jobFullName: state.jobFullName);
  }

  // ---------- 定位新构建（队列 + 历史时间戳兜底） ----------

  /// 本次 trigger 在 [ReservedBuildNumberRegistry] 中"占用"的 build 号下界。
  /// `_locateNewBuildOnce` 严格要求 `b.number >= _reservedMin`，避免多 tab 抢号。
  int? _reservedMin;

  void _startQueuePolling({required int reservedMin}) {
    _queuePollTimer?.cancel();
    _reservedMin = reservedMin;
    _locateNewBuildOnce();
    _queuePollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _locateNewBuildOnce(),
    );
  }

  /// 一次定位 tick：
  ///
  /// 1. 如果有合法 queue URL，先尝试 GET 拿到 `why` / `executable`；
  /// 2. 同时（或当 1 失败 / queue URL 不合法时）拉 build history，按 `triggeredAt`
  ///    时间戳找出新一次构建。
  ///
  /// 这样无论 Jenkins / 反代是否返回标准 `/queue/item/` 头，本地都能稳定地切到
  /// 真实的新构建上。
  Future<void> _locateNewBuildOnce() async {
    final triggeredAt = state.queueTriggeredAt;
    if (triggeredAt == null) {
      _queuePollTimer?.cancel();
      _queuePollTimer = null;
      return;
    }
    final repo = _repo();
    if (repo == null) return;

    state = state.copyWith(queueWaitedSeconds: state.queueWaitedSeconds + 2);

    final reservedMin = _reservedMin;

    final queueUrl = state.queueUrl;
    if (queueUrl != null) {
      try {
        final item = await repo.fetchQueueItem(queueUrl);
        if (item != null) {
          if (item.cancelled) {
            _queuePollTimer?.cancel();
            _queuePollTimer = null;
            state = state.copyWith(errorMessage: '构建在队列中被取消', clearQueue: true);
            return;
          }
          final number = item.executable?.number;
          // 即便 queue 给了 number，也要保证它不小于 reserved 下界
          // （罕见场景：队列项 stale，executable 指向了上一条 build）。
          if (number != null &&
              (reservedMin == null || number >= reservedMin)) {
            _attachToNewBuild(number);
            return;
          }
          final why = item.why;
          if (why != null && why.isNotEmpty) {
            state = state.copyWith(queueWhy: why);
          }
        }
      } catch (_) {
        // 忽略：继续走 history 兜底
      }
    }

    // 通过 builds history + triggeredAt 反查新构建
    try {
      final builds = await repo.fetchHistory(jobFullName, count: 10);
      const toleranceMs = 30 * 1000;
      final picked =
          builds
              .where((b) => b.timestamp >= triggeredAt - toleranceMs)
              .where((b) => reservedMin == null || b.number >= reservedMin)
              .toList()
            ..sort((a, b) => a.number.compareTo(b.number));
      if (picked.isEmpty) return;
      _attachToNewBuild(picked.first.number, prefetched: picked.first);
    } catch (_) {
      // 单次失败忽略，下次再试
    }
  }

  /// 切换到新的 build：停队列轮询、清掉旧 build 状态、起构建轮询。
  void _attachToNewBuild(int number, {JenkinsBuild? prefetched}) {
    _queuePollTimer?.cancel();
    _queuePollTimer = null;
    if (state.buildNumber == number && state.build != null) {
      // 已经在跟踪同一个 build，仅清队列即可
      state = state.copyWith(clearQueue: true);
      if (_buildPollTimer == null) _startBuildPolling(number);
      return;
    }
    state = state.copyWith(clearQueue: true, clearBuild: true);
    state = state.copyWith(buildNumber: number, build: prefetched);
    _startBuildPolling(number);
  }

  // ---------- 构建轮询 ----------

  void _startBuildPolling(int number) {
    _buildPollTimer?.cancel();
    _prefetchStageLayoutTemplate(number);
    _pollBuildOnce(number);
    _buildPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollBuildOnce(number),
    );
  }

  /// 从上一构建拉阶段名顺序，供运行中进度条「一次列出全部阶段」。
  Future<void> _prefetchStageLayoutTemplate(int currentNumber) async {
    if (currentNumber <= 1) return;
    final repo = _repo();
    if (repo == null) return;
    try {
      final prevStages = await repo.fetchStages(jobFullName, currentNumber - 1);
      if (!ref.mounted) return;
      if (state.buildNumber != currentNumber) return;
      if (prevStages.isEmpty) return;
      state = state.copyWith(stageLayoutTemplate: prevStages);
    } catch (_) {
      // 无上一跑或非 Pipeline：保持空模板，UI 仍按 Jenkins 增量列表展示
    }
  }

  Future<void> _pollBuildOnce(int number) async {
    final repo = _repo();
    if (repo == null) return;
    try {
      // 记录本次拉取前「这个 build 是否正被观察为运行中」，用于只在
      // 运行中 → 结束 的真实跳变时弹通知（避免回看历史构建时误弹）。
      final wasBuilding =
          state.buildNumber == number && state.build?.building == true;
      final build = await repo.fetchBuild(state.jobFullName, number);
      List<BuildStage> stages = state.stages;
      if (build.building || stages.isEmpty) {
        stages = await repo.fetchStages(state.jobFullName, number);
      }
      state = state.copyWith(build: build, stages: stages, clearError: true);
      if (!build.building) {
        if (wasBuilding) _notifyBuildFinished(number, build);
        _buildPollTimer?.cancel();
        _buildPollTimer = null;
        // build 整体已结束，但 wfapi/describe 偶尔还没把最后一个隐式 stage
        //（如 `Declarative: Post Actions`）从 IN_PROGRESS 收尾成 SUCCESS。
        // 延迟一次补拉一次 stages，让 UI 收尾干净。
        Future<void>.delayed(const Duration(milliseconds: 1500), () async {
          if (state.buildNumber != number) return; // 用户已经切到别的 build
          try {
            final finalStages = await repo.fetchStages(
              state.jobFullName,
              number,
            );
            if (finalStages.isNotEmpty) {
              state = state.copyWith(stages: finalStages);
            }
          } catch (_) {
            /* 忽略 */
          }
        });
      }
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  /// 构建结束（运行中 → 完成）时发通知。
  ///
  /// 两个通道相互独立：
  /// - 本地系统通知：由 [notificationsEnabledProvider] 控制（默认关、需系统权限）；
  /// - Slack 私信：由 Slack 配置自身控制（选了接收人 + 成功/失败开关），
  ///   不受本地通知开关影响——否则关掉本地通知会连 Slack 一起静默。
  void _notifyBuildFinished(int number, JenkinsBuild build) {
    // 本地系统通知
    if (ref.read(notificationsEnabledProvider)) {
      final isZh = ref.read(appLocaleProvider).languageCode == 'zh';
      final status = switch (build.resultEnum) {
        BuildResult.success => isZh ? '构建成功' : 'Build succeeded',
        BuildResult.failure => isZh ? '构建失败' : 'Build failed',
        BuildResult.unstable => isZh ? '构建不稳定' : 'Build unstable',
        BuildResult.aborted => isZh ? '构建已终止' : 'Build aborted',
        _ => isZh ? '构建结束' : 'Build finished',
      };
      unawaited(showBuildResultNotification(
        title: _notifyJobName,
        body: '#$number · $status',
      ));
    }

    // Slack 私信：发给本次发版选定的人（为空则不发），按设置过滤成功/失败。
    unawaited(ref.read(slackNotifierProvider).notifyBuildResult(
          recipients: _slackRecipients,
          jobFullName: _notifyJobName,
          number: number,
          result: build.resultEnum,
          url: build.url,
          durationMillis: build.duration,
        ));
  }

  /// 从 `https://.../queue/item/12345/` 中抽出数字 id（仅展示用途）。
  int? _extractQueueId(String queueUrl) {
    final m = RegExp(r'/queue/item/(\d+)/?').firstMatch(queueUrl);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }
}

/// 每次「立即构建」一个新的运行实例（独立的 ProgressPanel / LogViewer / 状态机），
/// 由 [RunHandle] 区分。同一 Job 的多次构建会有多个 controller 并存。
final releaseControllerProvider =
    NotifierProvider.family<ReleaseController, ReleaseRunState, RunHandle>(
      ReleaseController.new,
    );

final projectRunTabsProvider =
    NotifierProvider.family<
      ProjectRunTabsController,
      ProjectRunTabsState,
      ProjectRunTabsKey
    >(ProjectRunTabsController.new);
