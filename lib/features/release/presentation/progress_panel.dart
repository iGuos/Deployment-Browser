import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/duration_formatter.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/domain/jenkins_build.dart';
import '../application/release_controller.dart';

class ProgressPanel extends ConsumerStatefulWidget {
  const ProgressPanel({super.key, required this.handle});

  final RunHandle handle;

  @override
  ConsumerState<ProgressPanel> createState() => _ProgressPanelState();
}

class _ProgressPanelState extends ConsumerState<ProgressPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 心跳每秒触发 setState，仅用于刷新「已耗时」展示
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _confirmAndAbort(
    BuildContext context,
    ReleaseController controller,
    ReleaseRunState state,
  ) async {
    final number = state.buildNumber;
    if (number == null) return;
    final l10n = AppL10n.of(context);
    final palette = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.buildAbortConfirmTitle),
        content: Text(l10n.buildAbortConfirmBody(number)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: palette.danger),
            child: Text(l10n.buildAbortConfirmOk),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await controller.abortBuild();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = ref.watch(releaseControllerProvider(widget.handle));
    final controller = ref.read(releaseControllerProvider(widget.handle).notifier);

    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            state: state,
            onAbort: () => _confirmAndAbort(context, controller, state),
          ),
          Divider(height: 1, color: palette.borderSubtle),
          if (state.errorMessage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: palette.danger.withValues(alpha: 0.10),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: palette.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.errorMessage!,
                      style: TextStyle(color: palette.text, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          // 队列卡片与构建卡片可同时存在：
          // 上次构建还在运行 + 新一次刚被触发还在排队 → 都展示
          if (state.hasQueueWaiting)
            _QueueBody(state: state, onCancel: controller.cancelQueueWait),
          if (state.build != null)
            _BuildBody(state: state)
          else if (!state.hasQueueWaiting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
              child: Center(
                child: Text(
                  '尚未发起构建',
                  style: TextStyle(color: palette.muted, fontSize: 12.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onAbort});

  final ReleaseRunState state;
  final VoidCallback onAbort;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final color = _statusColor(palette);
    final label = _statusLabel(l10n);
    final canAbort = state.build?.building == true && state.buildNumber != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: palette.text, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 14),
          if (state.buildNumber != null)
            Text(
              '#${state.buildNumber}',
              style: TextStyle(color: palette.muted, fontSize: 12),
            )
          else if (state.queueItemId != null)
            Text(
              l10n.buildQueueId(state.queueItemId!),
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          const Spacer(),
          if (state.build != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${l10n.buildDuration}: ${formatDurationShort(state.build!.duration > 0 ? state.build!.duration : DateTime.now().millisecondsSinceEpoch - state.build!.timestamp)}',
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
          if (canAbort)
            TextButton.icon(
              onPressed: state.aborting ? null : onAbort,
              icon: state.aborting
                  ? const SizedBox(
                      width: 12, height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop_circle_outlined, size: 16),
              label: Text(state.aborting ? l10n.buildAborting : l10n.buildAbort),
              style: TextButton.styleFrom(
                foregroundColor: palette.danger,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  /// 状态文案优先级：构建中 / 已完成 > 排队中 > 触发中 > 未开始。
  /// 这样在「上次仍在运行、又点了新一次」的情况下，Header 仍然反映真正
  /// 在跑的那个构建，而队列等待状态由下方的卡片展示。
  String _statusLabel(AppL10n l10n) {
    final r = state.build?.resultEnum;
    if (r != null) {
      return switch (r) {
        BuildResult.success => l10n.buildSuccess,
        BuildResult.failure => l10n.buildFailed,
        BuildResult.unstable => l10n.buildUnstable,
        BuildResult.aborted => l10n.buildAborted,
        BuildResult.running => l10n.buildRunning,
        BuildResult.notBuilt => '未构建',
        BuildResult.unknown => '—',
      };
    }
    if (state.hasQueueWaiting) return l10n.buildQueued;
    if (state.triggering) return l10n.projectTriggering;
    return l10n.buildIdle;
  }

  Color _statusColor(AppPalette palette) {
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

class _QueueBody extends StatelessWidget {
  const _QueueBody({required this.state, required this.onCancel});

  final ReleaseRunState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final why = (state.queueWhy ?? '').trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: palette.warning),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  why.isEmpty ? l10n.buildQueueWaiting : why,
                  style: TextStyle(color: palette.text, fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.buildQueueWaitedFor(state.queueWaitedSeconds),
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: Text(l10n.buildQueueCancel),
              style: TextButton.styleFrom(
                foregroundColor: palette.muted,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BuildBody extends StatelessWidget {
  const _BuildBody({required this.state});

  final ReleaseRunState state;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final build = state.build!;
    // 优先用「按阶段」估算的进度（更直观、不会因本次比上次慢就提前到顶）；
    // 没有上一跑模板时退回到 Jenkins 时间估算。
    final progress = state.progressByStages ?? build.progress;
    final stages = state.stagesForProgressDisplay;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: build.building ? (progress > 0 ? progress : null) : 1.0,
              minHeight: 6,
              backgroundColor: palette.surfaceRaised,
              color: build.building
                  ? palette.accent
                  : (build.resultEnum == BuildResult.success ? palette.success : palette.danger),
            ),
          ),
          if (stages.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              AppL10n.of(context).buildStages,
              style: TextStyle(color: palette.muted, fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.4),
            ),
            const SizedBox(height: 8),
            ...stages.map((s) => _StageRow(stage: s, buildEnded: !build.building)),
          ],
        ],
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.buildEnded});

  final BuildStage stage;

  /// 整次构建是否已经结束。当 build 已结束但 wfapi/describe 还没把
  /// 隐式 stage（如 `Declarative: Post Actions`）从 IN_PROGRESS 收尾时，
  /// UI 不应继续显示「转圈圈」给用户造成"还在跑"的错觉。
  final bool buildEnded;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ic = _icon(stage, palette);
    final showAsRunning = stage.isRunning && !buildEnded;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          ic,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              stage.name,
              style: TextStyle(
                color: palette.text,
                fontSize: 12.5,
                fontWeight: showAsRunning ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            formatDurationShort(stage.durationMillis),
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _icon(BuildStage s, AppPalette p) {
    if (s.isSuccess) {
      return Icon(Icons.check_circle_rounded, size: 16, color: p.success);
    }
    if (s.isFailed) {
      return Icon(Icons.cancel_rounded, size: 16, color: p.danger);
    }
    if (s.isRunning && !buildEnded) {
      return SizedBox(
        width: 16, height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: p.running),
      );
    }
    // build 已结束 / 该 stage 未执行：显示中性占位
    return Icon(Icons.radio_button_unchecked_rounded, size: 16, color: p.muted);
  }
}
