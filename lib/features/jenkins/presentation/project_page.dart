import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/domain/jenkins_build.dart';
import '../../notifications/slack/slack_notifier.dart';
import '../../release/application/release_controller.dart';
import '../../release/presentation/log_viewer.dart';
import '../../release/presentation/progress_panel.dart';
import '../application/branch_defaults_provider.dart';
import '../application/job_alias_provider.dart';
import '../data/jenkins_repository.dart';
import '../data/project_detail_provider.dart';
import '../domain/build_parameter.dart';
import '../domain/jenkins_node.dart';
import 'parameter_form.dart';
import 'release_history_dialog.dart';

class ProjectPage extends ConsumerStatefulWidget {
  const ProjectPage({
    super.key,
    required this.jenkinsAccountId,
    required this.fullName,
    required this.displayName,
    required this.multibranch,
  });

  /// 本地 Jenkins 账号 id（与 [jenkinsRepositoryForAccountProvider] 一致）。
  final String jenkinsAccountId;
  final String fullName;
  final String displayName;
  final bool multibranch;

  @override
  ConsumerState<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends ConsumerState<ProjectPage> {
  String? _selectedBranchFullName;
  Map<String, String> _parameterValues = {};

  /// 当前开启「多选 → 发 N 次」的参数名（产品约束：最多一个），以及其勾选值。
  String? _multiSelectParam;
  List<String> _multiSelectValues = const [];

  /// 本次发版选定的 Slack 通知人（从设置候选池里挑；为空则不通知）。
  List<SlackRecipient> _notifyTargets = const [];

  String get _activeJobFullName =>
      widget.multibranch && _selectedBranchFullName != null
      ? _selectedBranchFullName!
      : widget.fullName;

  ProjectDetailKey _detailKey(String fullName) =>
      (accountId: widget.jenkinsAccountId, fullName: fullName);

  ProjectRunTabsKey get _runTabsKey =>
      (accountId: widget.jenkinsAccountId, fullName: widget.fullName);

  @override
  Widget build(BuildContext context) {
    final folderAsync = ref.watch(
      projectDetailProvider(_detailKey(widget.fullName)),
    );
    final paramsAsync = ref.watch(
      projectDetailProvider(_detailKey(_activeJobFullName)),
    );
    final runTabs = ref.watch(projectRunTabsProvider(_runTabsKey));
    final runTabsNotifier = ref.read(
      projectRunTabsProvider(_runTabsKey).notifier,
    );

    void invalidateDetail() {
      // 顺便丢掉 repo 层 (_jobClassCache / _branchOptionsCache)，否则即使 provider
      // 重拉了 job 定义，旧的 jobClass 和分支候选还在缓存里。
      final repo = ref.read(
        jenkinsRepositoryForAccountProvider(widget.jenkinsAccountId),
      );
      repo?.invalidateJobDetailCaches(widget.fullName);
      if (widget.fullName != _activeJobFullName) {
        repo?.invalidateJobDetailCaches(_activeJobFullName);
      }
      ref.invalidate(projectDetailProvider(_detailKey(widget.fullName)));
      ref.invalidate(projectDetailProvider(_detailKey(_activeJobFullName)));
    }

    // Riverpod 默认 skipLoadingOnRefresh: true，invalidate/refresh 时会保留上一帧 data，
    // 视觉上像「秒开」旧数据；关闭 tab 再打开需要明确展示加载态。
    return folderAsync.when(
      skipLoadingOnRefresh: false,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          _ErrorState(message: e.toString(), onRetry: invalidateDetail),
      data: (folderDetail) {
        return paramsAsync.when(
          skipLoadingOnRefresh: false,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              _ErrorState(message: e.toString(), onRetry: invalidateDetail),
          data: (paramsDetail) {
            return LayoutBuilder(
              builder: (ctx, c) {
                // 桌面壳有侧栏，内容区宽度常 < 1100；若仍用 [Breakpoints.tablet] 会误判为窄屏，
                // 首次打开窗口时构建卡片会叠在参数卡片下方。双栏改以内容区 >= 720 为准。
                final wide = c.maxWidth >= Breakpoints.mobile;
                final left = _LeftPane(
                  folderDetail: folderDetail,
                  paramsDetail: paramsDetail,
                  widget: widget,
                  selectedBranchFullName: _selectedBranchFullName,
                  onSelectBranch: (n) => setState(() {
                    _selectedBranchFullName = n;
                    _parameterValues = {};
                    // 换分支后参数定义可能不同，多选选择一并清掉，避免带着旧值发 N 次。
                    _multiSelectParam = null;
                    _multiSelectValues = const [];
                  }),
                  parameterValues: _parameterValues,
                  onChangeParameter: (k, v) => setState(
                    () => _parameterValues = {..._parameterValues, k: v},
                  ),
                  multiSelectParam: _multiSelectParam,
                  multiSelectValues: _multiSelectValues,
                  onToggleMultiSelect: (name, on) => setState(() {
                    _multiSelectParam = on ? name : null;
                    _multiSelectValues = const [];
                  }),
                  onChangeMultiSelectValues: (name, values) => setState(() {
                    _multiSelectParam = name;
                    _multiSelectValues = values;
                  }),
                  onTrigger: _onTrigger,
                  onRefresh: invalidateDetail,
                  activeJobFullName: _activeJobFullName,
                  activeRun: runTabs.activeRun,
                  notifyTargets: _notifyTargets,
                  onNotifyTargetsChanged: (v) => setState(() => _notifyTargets = v),
                );
                final right = _RightPane(
                  runs: runTabs.runs,
                  activeIndex: runTabs.activeIndex,
                  onSelect: runTabsNotifier.selectRun,
                  onClose: runTabsNotifier.closeRun,
                );

                if (wide) {
                  // 桌面窗口偏窄时左侧构建参数卡片少占宽度，把空间让给日志/进度区。
                  final narrowDesktop = c.maxWidth < 1320;
                  final leftFlex = narrowDesktop ? 4 : 5;
                  final rightFlex = narrowDesktop ? 7 : 6;
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: leftFlex, child: left),
                        const SizedBox(width: 16),
                        Expanded(flex: rightFlex, child: right),
                      ],
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    left,
                    const SizedBox(height: 12),
                    SizedBox(height: 540, child: right),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _onTrigger() async {
    if (widget.multibranch && _selectedBranchFullName == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择要发版的分支')));
      return;
    }
    final multiParam = _multiSelectParam;
    if (multiParam != null && _multiSelectValues.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).projectMultiSelectEmpty(multiParam)),
        ),
      );
      return;
    }
    final detail = await ref.read(
      projectDetailProvider(_detailKey(_activeJobFullName)).future,
    );
    final merged = BuildParameter.mergeForTrigger(
      detail.parameters,
      _parameterValues,
    );
    // 刷新后项目的枚举值可能已变化，勾选里过期的值直接丢掉，
    // 别拿去触发注定被 Jenkins 拒绝的构建。
    var multiValues = _multiSelectValues;
    if (multiParam != null) {
      final def = detail.parameters
          .where((p) => p.name == multiParam)
          .firstOrNull;
      if (def != null && def.choices.isNotEmpty) {
        multiValues = multiValues
            .where((v) => def.choices.contains(v))
            .toList(growable: false);
      }
      if (multiValues.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppL10n.of(context).projectMultiSelectEmpty(multiParam),
              ),
            ),
          );
        }
        return;
      }
    }
    // 多选 = 同一份参数按勾选的值展开成 N 份；底层仍是 N 次独立的普通触发。
    final variants = BuildParameter.expandForMultiTrigger(
      merged,
      multiParamName: multiParam,
      multiValues: multiValues,
    );

    final alias =
        ref.read(jobAliasProvider(widget.jenkinsAccountId))[widget.fullName];
    for (final variant in variants) {
      // 每一次触发都创建一个独立的 run（→ 独立 tab、独立 controller）。
      // run tab 状态放在 provider 中，避免关闭其它工程 tab 导致本页临时重建时丢失。
      final handle = ref
          .read(projectRunTabsProvider(_runTabsKey).notifier)
          .addRun(_activeJobFullName);
      final controller = ref.read(releaseControllerProvider(handle).notifier);
      await controller.trigger(
        parameters: variant.parameters,
        slackRecipients: _notifyTargets,
        jobAlias: alias,
        variantLabel: variant.label,
      );
    }

    // 本次发版的通知人已随 run 固化进对应 controller 状态（右侧表头展示）；
    // 清空发版页的选择，下一次构建从空白开始，避免误带上一次的通知人。
    if (mounted) {
      setState(() => _notifyTargets = const []);
      if (variants.length > 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppL10n.of(context).projectTriggeredTimes(variants.length),
            ),
          ),
        );
      }
    }
  }
}

class _LeftPane extends ConsumerWidget {
  const _LeftPane({
    required this.folderDetail,
    required this.paramsDetail,
    required this.widget,
    required this.selectedBranchFullName,
    required this.onSelectBranch,
    required this.parameterValues,
    required this.onChangeParameter,
    required this.multiSelectParam,
    required this.multiSelectValues,
    required this.onToggleMultiSelect,
    required this.onChangeMultiSelectValues,
    required this.onTrigger,
    required this.onRefresh,
    required this.activeJobFullName,
    required this.activeRun,
    required this.notifyTargets,
    required this.onNotifyTargetsChanged,
  });

  /// 多分支目录：分支列表、是否 multibranch。
  final ProjectDetail folderDetail;

  /// 实际触发构建的 Job（含选中分支）：参数定义以此为准。
  final ProjectDetail paramsDetail;
  final ProjectPage widget;
  final String? selectedBranchFullName;
  final void Function(String? fullName) onSelectBranch;
  final Map<String, String> parameterValues;
  final void Function(String key, String value) onChangeParameter;

  /// 「多选 → 发 N 次」当前状态（最多一个参数可多选）。
  final String? multiSelectParam;
  final List<String> multiSelectValues;
  final void Function(String paramName, bool enabled) onToggleMultiSelect;
  final void Function(String paramName, List<String> values)
      onChangeMultiSelectValues;

  final Future<void> Function() onTrigger;
  final VoidCallback onRefresh;
  final String activeJobFullName;

  /// 当前活动 tab 对应的 run。仅用于按钮 loading 态显示——避免在
  /// 「正在触发新 run」时让用户多次点击。
  final RunHandle? activeRun;

  /// 本次发版选定的通知人 + 变更回调。
  final List<SlackRecipient> notifyTargets;
  final ValueChanged<List<SlackRecipient>> onNotifyTargetsChanged;

  /// 弹框编辑本项目的通知别名（用于构建完成通知里替代冗长 Job 名）。
  Future<void> _editAlias(
    BuildContext context,
    WidgetRef ref,
    String? current,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _AliasEditDialog(
        initial: current ?? '',
        hintName: widget.displayName,
      ),
    );
    if (result == null) return; // 取消 / ESC
    await ref
        .read(jobAliasProvider(widget.jenkinsAccountId).notifier)
        .setAlias(widget.fullName, result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final triggering =
        activeRun != null &&
        ref.watch(
          releaseControllerProvider(activeRun!).select((s) => s.triggering),
        );
    final description = () {
      final p = (paramsDetail.description ?? '').trim();
      if (p.isNotEmpty) return p;
      return (folderDetail.description ?? '').trim();
    }();
    final alias = ref.watch(
      jobAliasProvider(widget.jenkinsAccountId).select((m) => m[widget.fullName]),
    );

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      padding: const EdgeInsets.all(18),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  folderDetail.isMultibranch
                      ? Icons.account_tree_rounded
                      : Icons.rocket_launch_rounded,
                  color: palette.info,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.displayName,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        activeJobFullName,
                        style: TextStyle(color: palette.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: l10n.commonRefresh,
                  waitDuration: const Duration(milliseconds: 300),
                  child: IconButton(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    color: palette.muted,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                description,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ],
            SizedBox(height: description.isNotEmpty ? 14 : 10),
            if (widget.multibranch) ...[
              _BranchSelector(
                subJobs: folderDetail.subJobs,
                selectedFullName: selectedBranchFullName,
                onSelect: onSelectBranch,
              ),
              const SizedBox(height: 14),
            ],
            ParameterForm(
              parameters: paramsDetail.parameters,
              values: parameterValues,
              onChange: onChangeParameter,
              multiSelectParam: multiSelectParam,
              multiSelectValues: multiSelectValues,
              onToggleMultiSelect: onToggleMultiSelect,
              onChangeMultiSelectValues: onChangeMultiSelectValues,
              branchOptionsLoader: (paramName, {bool forceRefresh = false}) async {
                final repo = ref.read(
                  jenkinsRepositoryForAccountProvider(widget.jenkinsAccountId),
                );
                if (repo == null) return const [];
                return repo.fetchBranchOptions(
                  activeJobFullName,
                  paramName,
                  forceRefresh: forceRefresh,
                );
              },
              // ref.watch 让星标状态在保存 / 清除后立刻刷新（不只是页面下次进入才更新）
              branchDefaultGetter: (paramName) => ref
                  .watch(branchDefaultsProvider(widget.jenkinsAccountId))[activeJobFullName]
                  ?[paramName],
              onSaveBranchDefault: (paramName, value) {
                ref
                    .read(branchDefaultsProvider(widget.jenkinsAccountId).notifier)
                    .setDefault(activeJobFullName, paramName, value);
              },
              onClearBranchDefault: (paramName) {
                ref
                    .read(branchDefaultsProvider(widget.jenkinsAccountId).notifier)
                    .clearDefault(activeJobFullName, paramName);
              },
              onShowReleaseHistory:
                  widget.multibranch && selectedBranchFullName == null
                  ? null
                  : () async {
                      if (ref.read(
                            jenkinsRepositoryForAccountProvider(
                              widget.jenkinsAccountId,
                            ),
                          ) ==
                          null) {
                        return;
                      }
                      await showReleaseHistoryDialog(
                        context: context,
                        jenkinsAccountId: widget.jenkinsAccountId,
                        jobFullName: activeJobFullName,
                      );
                    },
            ),
            Consumer(
              builder: (ctx, ref2, _) {
                final slackCfg = ref2.watch(slackConfigProvider);
                if (!slackCfg.isConfigured) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _NotifyTargetField(
                    pool: slackCfg.recipients,
                    selected: notifyTargets,
                    onChanged: onNotifyTargetsChanged,
                    alias: alias,
                    onEditAlias: () => _editAlias(context, ref, alias),
                  ),
                );
              },
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              icon: triggering
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(
                triggering
                    ? l10n.projectTriggering
                    : (multiSelectValues.length > 1
                          ? l10n.projectTriggerTimes(multiSelectValues.length)
                          : l10n.projectTrigger),
              ),
              onPressed: triggering ? null : onTrigger,
              style: FilledButton.styleFrom(
                backgroundColor: palette.accent,
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右侧多 tab 容器：每个 tab 对应一次「立即构建」的运行实例。
///
/// 设计要点：
/// - 每个 tab 内部由 [ProgressPanel] + [LogViewer] 组成，都通过 [RunHandle]
///   绑定到独立的 [releaseControllerProvider] 实例；
/// - tab 标题展示 build 序号（拿到后）+ 运行状态色点；
/// - 支持关闭 tab，关闭时会 invalidate 对应 controller 释放定时器；
/// - 当 [runs] 为空（未发起过构建）显示空态。
class _RightPane extends ConsumerWidget {
  const _RightPane({
    required this.runs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
  });

  final List<RunHandle> runs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;

    if (runs.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.borderSubtle),
        ),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.rocket_launch_outlined,
                size: 28,
                color: palette.muted,
              ),
              const SizedBox(height: 10),
              Text(
                '点击「立即构建」开始',
                style: TextStyle(color: palette.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final clamped = activeIndex.clamp(0, runs.length - 1);
    final activeHandle = runs[clamped];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RunTabBar(
          runs: runs,
          activeIndex: clamped,
          onSelect: onSelect,
          onClose: onClose,
        ),
        const SizedBox(height: 10),
        // 用 KeyedSubtree + ValueKey 把每个 tab 的子树独立化：切 tab 时
        // 不会复用上一个 tab 的 ProgressPanel/LogViewer state（如日志滚动位置）。
        KeyedSubtree(
          key: ValueKey('progress-${activeHandle.runId}'),
          child: ProgressPanel(handle: activeHandle),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('log-${activeHandle.runId}'),
            child: LogViewer(handle: activeHandle),
          ),
        ),
      ],
    );
  }
}

/// 横排 tab 头：显示每个 run 的状态点 + #buildNumber + 关闭按钮。
class _RunTabBar extends ConsumerWidget {
  const _RunTabBar({
    required this.runs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
  });

  final List<RunHandle> runs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: runs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (ctx, i) {
          final h = runs[i];
          final state = ref.watch(releaseControllerProvider(h));
          final isActive = i == activeIndex;
          final color = _runColor(state, palette);
          final label = _runLabel(state, i);
          return InkWell(
            onTap: () => onSelect(i),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isActive ? palette.surfaceRaised : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isActive ? palette.borderSubtle : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: isActive ? palette.text : palette.muted,
                      fontSize: 12,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => onClose(i),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: palette.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _runLabel(ReleaseRunState state, int index) {
    // 一次点击因多选展开出的多个 run，只靠 #号 / 队列号区分不了「哪一路」，
    // 所以带上多选取值（如 `#128 · admin-api`）。
    final variant = state.variantLabel;
    final suffix = (variant == null || variant.isEmpty) ? '' : ' · $variant';
    if (state.buildNumber != null) return '#${state.buildNumber}$suffix';
    if (state.queueItemId != null) return '队列 ${state.queueItemId}$suffix';
    if (state.triggering) return '触发中$suffix';
    return '运行 ${index + 1}$suffix';
  }

  Color _runColor(ReleaseRunState state, AppPalette palette) {
    final r = state.build?.resultEnum;
    if (r != null) {
      return switch (r) {
        BuildResult.success => palette.success,
        BuildResult.failure => palette.danger,
        BuildResult.unstable => palette.warning,
        BuildResult.aborted => palette.muted,
        BuildResult.running => palette.running,
        BuildResult.notBuilt => palette.muted,
        BuildResult.unknown => palette.muted,
      };
    }
    if (state.hasQueueWaiting || state.triggering) return palette.warning;
    return palette.muted;
  }
}

class _BranchSelector extends StatelessWidget {
  const _BranchSelector({
    required this.subJobs,
    required this.selectedFullName,
    required this.onSelect,
  });

  final List<JenkinsNode> subJobs;
  final String? selectedFullName;
  final void Function(String? fullName) onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);

    if (subJobs.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: palette.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.projectNoBranches,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.projectBranch,
          style: TextStyle(
            color: palette.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: selectedFullName,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.alt_route_rounded, size: 18),
          ),
          items: subJobs
              .map(
                (n) => DropdownMenuItem<String>(
                  value: n.fullName,
                  child: Text(n.name, style: const TextStyle(fontSize: 13)),
                ),
              )
              .toList(),
          onChanged: (v) => onSelect(v),
          hint: Text('选择分支', style: TextStyle(color: palette.muted)),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: palette.danger, size: 32),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text, fontSize: 13),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(AppL10n.of(context).commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「构建完成通知」选择框：从设置的候选池里多选本次要私信的人。
class _NotifyTargetField extends StatelessWidget {
  const _NotifyTargetField({
    required this.pool,
    required this.selected,
    required this.onChanged,
    required this.alias,
    required this.onEditAlias,
  });

  final List<SlackRecipient> pool;
  final List<SlackRecipient> selected;
  final ValueChanged<List<SlackRecipient>> onChanged;

  /// 本项目的通知别名（用于通知文案里替代冗长 Job 名）；为空表示未设置。
  final String? alias;
  final VoidCallback onEditAlias;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final hasAlias = alias != null && alias!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.notifications_active_outlined, size: 15, color: palette.info),
            const SizedBox(width: 8),
            Text(l10n.projectNotifyLabel,
                style: TextStyle(color: palette.muted, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            if (hasAlias)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: palette.info.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${l10n.projectAliasBadge}: ${alias!}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.info, fontSize: 11),
                    ),
                  ),
                ),
              )
            else
              const Spacer(),
            Tooltip(
              message: l10n.projectAliasTooltip,
              waitDuration: const Duration(milliseconds: 300),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onEditAlias,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.edit_outlined, size: 15, color: palette.muted),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final result = await showDialog<List<SlackRecipient>>(
              context: context,
              builder: (_) => _PoolPickerDialog(pool: pool, initial: selected),
            );
            if (result != null) onChanged(result);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: selected.isEmpty
                      ? Text(l10n.projectNotifyPick,
                          style: TextStyle(color: palette.muted, fontSize: 13))
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final r in selected)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: palette.info.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(r.label,
                                    style: TextStyle(color: palette.text, fontSize: 12)),
                              ),
                          ],
                        ),
                ),
                Icon(Icons.arrow_drop_down_rounded, color: palette.muted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 从候选池多选（本地数据,无网络请求）。
class _PoolPickerDialog extends StatefulWidget {
  const _PoolPickerDialog({required this.pool, required this.initial});

  final List<SlackRecipient> pool;
  final List<SlackRecipient> initial;

  @override
  State<_PoolPickerDialog> createState() => _PoolPickerDialogState();
}

class _PoolPickerDialogState extends State<_PoolPickerDialog> {
  late final Map<String, SlackRecipient> _selected = {
    for (final r in widget.initial) r.id: r,
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(l10n.projectNotifyPick),
      content: SizedBox(
        width: 380,
        height: (size.height * 0.5).clamp(220.0, 460.0),
        child: widget.pool.isEmpty
            ? Center(
                child: Text(l10n.slackNoRecipients,
                    style: TextStyle(color: palette.muted, fontSize: 12)))
            : ListView.builder(
                itemCount: widget.pool.length,
                itemBuilder: (c, i) {
                  final r = widget.pool[i];
                  return CheckboxListTile(
                    dense: true,
                    value: _selected.containsKey(r.id),
                    title: Text(r.label, style: const TextStyle(fontSize: 13)),
                    subtitle: r.email.isNotEmpty
                        ? Text(r.email, style: TextStyle(color: palette.muted, fontSize: 10.5))
                        : null,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected[r.id] = r;
                      } else {
                        _selected.remove(r.id);
                      }
                    }),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.values.toList()),
          child: Text('${l10n.commonConfirm} (${_selected.length})'),
        ),
      ],
    );
  }
}

/// 通知别名编辑弹框。自持 [TextEditingController]，在 [State.dispose] 里释放——
/// 这样无论是点「保存 / 取消」还是按 ESC 关闭，控制器都在路由完全移除后才销毁，
/// 不会在退场动画中被仍然挂载的 TextField 引用到（否则会触发 framework 断言崩溃）。
class _AliasEditDialog extends StatefulWidget {
  const _AliasEditDialog({required this.initial, required this.hintName});

  final String initial;
  final String hintName;

  @override
  State<_AliasEditDialog> createState() => _AliasEditDialogState();
}

class _AliasEditDialogState extends State<_AliasEditDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    return AlertDialog(
      title: Text(l10n.projectAliasDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.projectAliasDialogHint,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              labelText: l10n.projectAliasField,
              hintText: widget.hintName,
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: Text(l10n.settingsSave),
        ),
      ],
    );
  }
}
