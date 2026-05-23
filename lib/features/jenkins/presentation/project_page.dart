import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/domain/jenkins_build.dart';
import '../../release/application/release_controller.dart';
import '../../release/presentation/log_viewer.dart';
import '../../release/presentation/progress_panel.dart';
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
                  }),
                  parameterValues: _parameterValues,
                  onChangeParameter: (k, v) => setState(
                    () => _parameterValues = {..._parameterValues, k: v},
                  ),
                  onTrigger: _onTrigger,
                  activeJobFullName: _activeJobFullName,
                  activeRun: runTabs.activeRun,
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
    final detail = await ref.read(
      projectDetailProvider(_detailKey(_activeJobFullName)).future,
    );
    final merged = BuildParameter.mergeForTrigger(
      detail.parameters,
      _parameterValues,
    );

    // 每次点击都创建一个独立的 run（→ 独立 tab、独立 controller）。
    // run tab 状态放在 provider 中，避免关闭其它工程 tab 导致本页临时重建时丢失。
    final handle = ref
        .read(projectRunTabsProvider(_runTabsKey).notifier)
        .addRun(_activeJobFullName);
    final controller = ref.read(releaseControllerProvider(handle).notifier);
    await controller.trigger(parameters: merged);
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
    required this.onTrigger,
    required this.activeJobFullName,
    required this.activeRun,
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
  final Future<void> Function() onTrigger;
  final String activeJobFullName;

  /// 当前活动 tab 对应的 run。仅用于按钮 loading 态显示——避免在
  /// 「正在触发新 run」时让用户多次点击。
  final RunHandle? activeRun;

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
                triggering ? l10n.projectTriggering : l10n.projectTrigger,
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
    if (state.buildNumber != null) return '#${state.buildNumber}';
    if (state.queueItemId != null) return '队列 ${state.queueItemId}';
    if (state.triggering) return '触发中';
    return '运行 ${index + 1}';
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
