import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../application/release_controller.dart';

/// 实时控制台日志（progressiveText 增量轮询）。
class LogViewer extends ConsumerStatefulWidget {
  const LogViewer({super.key, required this.handle});

  final RunHandle handle;

  @override
  ConsumerState<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends ConsumerState<LogViewer> {
  static const _maxRows = 5000;

  final ScrollController _scroll = ScrollController();
  final ValueNotifier<int> _panelRevision = ValueNotifier(0);
  final TextEditingController _filter = TextEditingController();
  final List<_LogEntry> _entries = [];
  ScrollController? _expandedScroll;
  Timer? _timer;
  int _start = 0;
  int? _attachedBuild;
  int? _scheduledBuild;
  int _nextLineNumber = 1;
  String _pendingLine = '';
  bool _autoScroll = true;
  bool _busy = false;
  bool _attachScheduled = false;
  Object? _lastError;
  DateTime? _lastReceivedAt;
  _LogLevelFilter _levelFilter = _LogLevelFilter.all;
  _LogViewMode _viewMode = _LogViewMode.plain;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _filter.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = (pos.maxScrollExtent - pos.pixels).abs() < 24;
    if (atBottom != _autoScroll) {
      setState(() => _autoScroll = atBottom);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _panelRevision.dispose();
    _filter.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _scheduleAttach(int? buildNumber) {
    if (buildNumber == _attachedBuild && !_attachScheduled) return;
    _scheduledBuild = buildNumber;
    if (_attachScheduled) return;
    _attachScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _scheduledBuild;
      _scheduledBuild = null;
      _attachScheduled = false;
      if (target == _attachedBuild) return;
      _attachToBuild(target);
    });
  }

  void _attachToBuild(int? buildNumber) {
    _timer?.cancel();
    _timer = null;
    if (buildNumber == null) {
      setState(() {
        _entries.clear();
        _pendingLine = '';
        _start = 0;
        _nextLineNumber = 1;
        _attachedBuild = null;
        _busy = false;
        _lastError = null;
        _lastReceivedAt = null;
      });
      _notifyPanelChanged();
      return;
    }

    setState(() {
      _entries.clear();
      _pendingLine = '';
      _start = 0;
      _nextLineNumber = 1;
      _attachedBuild = buildNumber;
      _busy = false;
      _lastError = null;
      _lastReceivedAt = null;
    });
    _notifyPanelChanged();
    _pollOnce();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final buildNumber = _attachedBuild;
    if (_busy || buildNumber == null) return;
    final repo = ref.read(
      jenkinsRepositoryForAccountProvider(widget.handle.jenkinsAccountId),
    );
    if (repo == null) return;
    setState(() => _busy = true);
    var catchUp = false;
    try {
      final res = await repo.fetchLog(
        widget.handle.jobFullName,
        buildNumber,
        start: _start,
      );
      if (!mounted || buildNumber != _attachedBuild) return;
      final now = DateTime.now();
      if (res.text.isNotEmpty) {
        _appendChunk(res.text, res.nextStart, now);
        if (_autoScroll) _jumpToEnd();
      } else {
        setState(() {
          _start = res.nextStart;
          _lastError = null;
          _lastReceivedAt = now;
        });
      }
      if (!res.hasMore &&
          (ref.read(releaseControllerProvider(widget.handle)).build?.building !=
              true)) {
        _flushPendingLine(now);
        _timer?.cancel();
        _timer = null;
      } else if (res.hasMore) {
        catchUp = true;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _lastError = e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (catchUp && mounted) {
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (mounted) _pollOnce();
        });
      }
    }
  }

  void _appendChunk(String text, int nextStart, DateTime receivedAt) {
    final merged = '$_pendingLine$text';
    final parts = merged.split('\n');
    final endedWithBreak = merged.endsWith('\n');
    if (endedWithBreak) {
      if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
      _pendingLine = '';
    } else {
      _pendingLine = parts.isEmpty ? '' : parts.removeLast();
    }

    final next = parts
        .map(_normalizeLine)
        .map(
          (line) => _LogEntry(
            lineNumber: _nextLineNumber++,
            text: line,
            level: _detectLevel(line),
            receivedAt: receivedAt,
          ),
        )
        .toList(growable: false);

    setState(() {
      _entries.addAll(next);
      _start = nextStart;
      _lastError = null;
      _lastReceivedAt = receivedAt;
      _trimRows();
    });
    _notifyPanelChanged();
  }

  void _flushPendingLine(DateTime receivedAt) {
    if (_pendingLine.isEmpty) return;
    final line = _normalizeLine(_pendingLine);
    setState(() {
      _entries.add(
        _LogEntry(
          lineNumber: _nextLineNumber++,
          text: line,
          level: _detectLevel(line),
          receivedAt: receivedAt,
        ),
      );
      _pendingLine = '';
      _trimRows();
    });
    _notifyPanelChanged();
  }

  void _trimRows() {
    if (_entries.length <= _maxRows) return;
    _entries.removeRange(0, _entries.length - _maxRows);
  }

  static String _normalizeLine(String line) {
    return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
  }

  static _LogLevel _detectLevel(String text) {
    final lower = text.toLowerCase();
    if (const [
      'error',
      'failed',
      'failure',
      'fatal',
      'exception',
    ].any(lower.contains)) {
      return _LogLevel.error;
    }
    if (const ['warn', 'deprecated'].any(lower.contains)) {
      return _LogLevel.warning;
    }
    return _LogLevel.info;
  }

  List<_LogEntry> get _visibleEntries {
    final query = _filter.text.trim().toLowerCase();
    return _entries
        .where((entry) {
          final levelMatched = switch (_levelFilter) {
            _LogLevelFilter.all => true,
            _LogLevelFilter.errors => entry.level == _LogLevel.error,
            _LogLevelFilter.warnings => entry.level == _LogLevel.warning,
          };
          if (!levelMatched) return false;
          if (query.isEmpty) return true;
          return entry.text.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  void _clearVisibleLog() {
    setState(() {
      _entries.clear();
      _pendingLine = '';
      _nextLineNumber = 1;
    });
    _notifyPanelChanged();
  }

  Future<void> _copyVisibleLog() async {
    final rows = _visibleEntries;
    if (rows.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: rows.map((e) => e.text).join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制当前日志')));
  }

  void _toggleAutoScroll() {
    setState(() => _autoScroll = !_autoScroll);
    if (!_autoScroll) return;
    _jumpToEnd();
  }

  void _setViewMode(_LogViewMode mode) {
    if (_viewMode == mode) return;
    setState(() => _viewMode = mode);
    if (_autoScroll) _jumpToEnd();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in [_scroll, _expandedScroll]) {
        if (controller?.hasClients ?? false) {
          controller!.jumpTo(controller.position.maxScrollExtent);
        }
      }
    });
  }

  void _notifyPanelChanged() {
    _panelRevision.value += 1;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(releaseControllerProvider(widget.handle));
    _scheduleAttach(state.buildNumber);
    return _buildLogPanel(
      context,
      viewMode: _viewMode,
      scrollController: _scroll,
      onViewModeChanged: _setViewMode,
      onExpand: _showExpandedLogDialog,
      onPanelChanged: null,
    );
  }

  Widget _buildLogPanel(
    BuildContext context, {
    required _LogViewMode viewMode,
    required ValueChanged<_LogViewMode> onViewModeChanged,
    required ScrollController? scrollController,
    required VoidCallback? onExpand,
    required VoidCallback? onPanelChanged,
  }) {
    final palette = context.palette;
    final colors = _LogViewerColors.of(context);
    final l10n = AppL10n.of(context);
    final visible = _visibleEntries;

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        children: [
          _NetworkToolbar(
            title: l10n.buildLog,
            buildNumber: _attachedBuild,
            filter: _filter,
            levelFilter: _levelFilter,
            busy: _busy,
            hasError: _lastError != null,
            autoScroll: _autoScroll,
            totalCount: _entries.length,
            visibleCount: visible.length,
            viewMode: viewMode,
            onClear: () {
              _clearVisibleLog();
              onPanelChanged?.call();
            },
            onCopy: _copyVisibleLog,
            onToggleAutoScroll: () {
              _toggleAutoScroll();
              onPanelChanged?.call();
            },
            onLevelFilterChanged: (value) {
              setState(() => _levelFilter = value);
              onPanelChanged?.call();
            },
            onViewModeChanged: onViewModeChanged,
            onExpand: onExpand,
            onFilterChanged: onPanelChanged,
          ),
          if (viewMode == _LogViewMode.table) const _NetworkHeader(),
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: _EmptyLogState(
                      text: _attachedBuild == null ? '尚未开始构建' : '等待日志…',
                    ),
                  )
                : visible.isEmpty
                ? const Center(child: _EmptyLogState(text: '没有匹配的日志'))
                : viewMode == _LogViewMode.plain
                ? _PlainLogContent(
                    entries: visible,
                    scrollController: scrollController,
                  )
                : ListView.builder(
                    controller: scrollController,
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    itemBuilder: (ctx, i) =>
                        _NetworkLogRow(entry: visible[i], index: i),
                  ),
          ),
          _NetworkStatusBar(
            totalCount: _entries.length,
            visibleCount: visible.length,
            lastReceivedAt: _lastReceivedAt,
            lastError: _lastError,
            startOffset: _start,
          ),
        ],
      ),
    );
  }

  Future<void> _showExpandedLogDialog() async {
    var dialogMode = _viewMode;
    final expandedScroll = ScrollController();
    _expandedScroll = expandedScroll;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return ValueListenableBuilder<int>(
                valueListenable: _panelRevision,
                builder: (context, _, _) {
                  final size = MediaQuery.sizeOf(context);
                  return Dialog(
                    child: SizedBox(
                      width: math.min(1180, size.width - 56),
                      height: math.min(760, size.height - 56),
                      child: _buildLogPanel(
                        context,
                        viewMode: dialogMode,
                        scrollController: expandedScroll,
                        onViewModeChanged: (mode) {
                          setState(() => _viewMode = mode);
                          setDialogState(() => dialogMode = mode);
                          if (_autoScroll) _jumpToEnd();
                        },
                        onExpand: null,
                        onPanelChanged: () {
                          _notifyPanelChanged();
                          setDialogState(() {});
                        },
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      );
    } finally {
      if (identical(_expandedScroll, expandedScroll)) {
        _expandedScroll = null;
      }
      expandedScroll.dispose();
    }
  }
}

enum _LogLevel { info, warning, error }

enum _LogLevelFilter { all, errors, warnings }

enum _LogViewMode { plain, table }

class _LogEntry {
  const _LogEntry({
    required this.lineNumber,
    required this.text,
    required this.level,
    required this.receivedAt,
  });

  final int lineNumber;
  final String text;
  final _LogLevel level;
  final DateTime receivedAt;
}

class _LogViewerColors {
  const _LogViewerColors({
    required this.panel,
    required this.toolbar,
    required this.header,
    required this.row,
    required this.rowAlt,
    required this.border,
    required this.rowBorder,
    required this.text,
    required this.muted,
    required this.accent,
    required this.error,
    required this.warning,
    required this.success,
  });

  final Color panel;
  final Color toolbar;
  final Color header;
  final Color row;
  final Color rowAlt;
  final Color border;
  final Color rowBorder;
  final Color text;
  final Color muted;
  final Color accent;
  final Color error;
  final Color warning;
  final Color success;

  factory _LogViewerColors.of(BuildContext context) {
    final palette = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stripe = isDark
        ? Colors.white.withValues(alpha: 0.025)
        : Colors.black.withValues(alpha: 0.025);

    return _LogViewerColors(
      panel: palette.editorBg,
      toolbar: palette.chromeBar,
      header: palette.surfaceRaised,
      row: palette.editorBg,
      rowAlt: Color.alphaBlend(stripe, palette.editorBg),
      border: palette.borderSubtle,
      rowBorder: palette.splitLine,
      text: palette.text,
      muted: palette.muted,
      accent: palette.accent,
      error: palette.danger,
      warning: palette.warning,
      success: palette.success,
    );
  }
}

class _NetworkToolbar extends StatelessWidget {
  const _NetworkToolbar({
    required this.title,
    required this.buildNumber,
    required this.filter,
    required this.levelFilter,
    required this.busy,
    required this.hasError,
    required this.autoScroll,
    required this.totalCount,
    required this.visibleCount,
    required this.viewMode,
    required this.onClear,
    required this.onCopy,
    required this.onToggleAutoScroll,
    required this.onLevelFilterChanged,
    required this.onViewModeChanged,
    required this.onExpand,
    required this.onFilterChanged,
  });

  final String title;
  final int? buildNumber;
  final TextEditingController filter;
  final _LogLevelFilter levelFilter;
  final bool busy;
  final bool hasError;
  final bool autoScroll;
  final int totalCount;
  final int visibleCount;
  final _LogViewMode viewMode;
  final VoidCallback onClear;
  final VoidCallback onCopy;
  final VoidCallback onToggleAutoScroll;
  final ValueChanged<_LogLevelFilter> onLevelFilterChanged;
  final ValueChanged<_LogViewMode> onViewModeChanged;
  final VoidCallback? onExpand;
  final VoidCallback? onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colors = _LogViewerColors.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.toolbar,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 680;
          final veryCompact = constraints.maxWidth < 520;
          return Row(
            children: [
              Icon(
                Icons.radio_button_checked_rounded,
                size: 14,
                color: palette.danger,
              ),
              if (!compact) ...[
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              _ToolbarIconButton(
                tooltip: '清空日志',
                icon: Icons.clear_all_rounded,
                onPressed: onClear,
              ),
              _ToolbarIconButton(
                tooltip: '复制当前日志',
                icon: Icons.copy_rounded,
                onPressed: visibleCount == 0 ? null : onCopy,
              ),
              if (!veryCompact) ...[
                const SizedBox(width: 4),
                _LevelChip(
                  label: '纯日志',
                  selected: viewMode == _LogViewMode.plain,
                  onTap: () => onViewModeChanged(_LogViewMode.plain),
                ),
                _LevelChip(
                  label: '表格日志',
                  selected: viewMode == _LogViewMode.table,
                  onTap: () => onViewModeChanged(_LogViewMode.table),
                ),
              ] else
                _ToolbarIconButton(
                  tooltip: viewMode == _LogViewMode.table
                      ? '切换到纯日志'
                      : '切换到表格日志',
                  icon: viewMode == _LogViewMode.table
                      ? Icons.notes_rounded
                      : Icons.table_rows_rounded,
                  selected: true,
                  onPressed: () => onViewModeChanged(
                    viewMode == _LogViewMode.table
                        ? _LogViewMode.plain
                        : _LogViewMode.table,
                  ),
                ),
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: colors.border,
              ),
              Expanded(
                child: _FilterInput(
                  controller: filter,
                  onChanged: onFilterChanged,
                ),
              ),
              if (!veryCompact) ...[
                const SizedBox(width: 8),
                _LevelChip(
                  label: 'All',
                  selected: levelFilter == _LogLevelFilter.all,
                  onTap: () => onLevelFilterChanged(_LogLevelFilter.all),
                ),
                _LevelChip(
                  label: compact ? 'Err' : 'Errors',
                  selected: levelFilter == _LogLevelFilter.errors,
                  color: colors.error,
                  onTap: () => onLevelFilterChanged(_LogLevelFilter.errors),
                ),
                _LevelChip(
                  label: compact ? 'Warn' : 'Warnings',
                  selected: levelFilter == _LogLevelFilter.warnings,
                  color: colors.warning,
                  onTap: () => onLevelFilterChanged(_LogLevelFilter.warnings),
                ),
              ],
              if (!compact && buildNumber != null) ...[
                const SizedBox(width: 8),
                Text(
                  '#$buildNumber',
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
              ],
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  hasError
                      ? Icons.cloud_off_rounded
                      : Icons.check_circle_rounded,
                  size: 14,
                  color: hasError ? colors.error : colors.success,
                ),
              if (!compact) ...[
                const SizedBox(width: 8),
                Text(
                  '$visibleCount / $totalCount',
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
              ],
              const SizedBox(width: 4),
              _ToolbarIconButton(
                tooltip: autoScroll ? '关闭自动滚动' : '开启自动滚动',
                icon: autoScroll
                    ? Icons.vertical_align_bottom_rounded
                    : Icons.lock_rounded,
                selected: autoScroll,
                onPressed: onToggleAutoScroll,
              ),
              if (onExpand != null)
                _ToolbarIconButton(
                  tooltip: '放大日志',
                  icon: Icons.open_in_full_rounded,
                  onPressed: onExpand,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FilterInput extends StatelessWidget {
  const _FilterInput({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    return SizedBox(
      height: 28,
      child: TextField(
        controller: controller,
        onChanged: (_) => onChanged?.call(),
        style: TextStyle(color: colors.text, fontSize: 12),
        cursorColor: colors.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Filter',
          hintStyle: TextStyle(color: colors.muted, fontSize: 12),
          prefixIcon: Icon(
            Icons.filter_alt_outlined,
            size: 15,
            color: colors.muted,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空过滤',
                  onPressed: () {
                    controller.clear();
                    onChanged?.call();
                  },
                  icon: const Icon(Icons.close_rounded, size: 14),
                  color: colors.muted,
                  padding: EdgeInsets.zero,
                ),
          filled: true,
          fillColor: colors.panel,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: colors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: colors.accent),
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        color: selected ? colors.accent : colors.muted,
        disabledColor: colors.muted.withValues(alpha: 0.35),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _CursorHint extends StatefulWidget {
  const _CursorHint({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<_CursorHint> createState() => _CursorHintState();
}

class _CursorHintState extends State<_CursorHint> {
  OverlayEntry? _entry;
  Offset _position = Offset.zero;

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  void _show(Offset position) {
    _position = position;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(
      builder: (context) {
        final colors = _LogViewerColors.of(context);
        final size = MediaQuery.sizeOf(context);
        final left = math.max(
          8.0,
          math.min(_position.dx + 12, size.width - 220),
        );
        final top = math.max(
          8.0,
          math.min(_position.dy + 16, size.height - 44),
        );
        return Positioned(
          left: left,
          top: top,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.header,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.16),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Text(
                      widget.message,
                      style: TextStyle(color: colors.text, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) => _show(event.position),
      onHover: (event) => _show(event.position),
      onExit: (_) => _hide(),
      child: widget.child,
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final chipColor = color ?? colors.accent;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? chipColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? chipColor.withValues(alpha: 0.72)
                  : colors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? chipColor : colors.muted,
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlainLogContent extends StatelessWidget {
  const _PlainLogContent({
    required this.entries,
    required this.scrollController,
  });

  final List<_LogEntry> entries;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final text = entries.map((entry) => entry.text).join('\n');
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.all(10),
      child: SelectableText(
        text,
        style: TextStyle(
          color: colors.text,
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
  }
}

class _NetworkHeader extends StatelessWidget {
  const _NetworkHeader();

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: colors.header,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: const Row(
        children: [
          _HeaderCell(label: '#', width: 56, align: TextAlign.right),
          _HeaderCell(label: 'Level', width: 88),
          Expanded(child: _HeaderCell(label: 'Message')),
          _HeaderCell(label: 'Time', width: 88),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.label,
    this.width,
    this.align = TextAlign.left,
  });

  final String label;
  final double? width;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final text = Text(
      label,
      textAlign: align,
      style: TextStyle(
        color: colors.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    );
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: align == TextAlign.right
          ? Alignment.centerRight
          : Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: text,
    );
    if (width == null) return child;
    return SizedBox(width: width, child: child);
  }
}

class _NetworkLogRow extends StatelessWidget {
  const _NetworkLogRow({required this.entry, required this.index});

  final _LogEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final levelColor = _levelColor(entry.level, colors);
    return _CursorHint(
      message: '双击查看完整日志',
      child: InkWell(
        onDoubleTap: () => _showMessageDialog(context),
        child: Container(
          height: 28,
          decoration: BoxDecoration(
            color: index.isEven ? colors.row : colors.rowAlt,
            border: Border(bottom: BorderSide(color: colors.rowBorder)),
          ),
          child: Row(
            children: [
              _BodyCell(
                width: 56,
                align: Alignment.centerRight,
                child: Text(
                  entry.lineNumber.toString(),
                  style: TextStyle(
                    color: colors.muted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
              _BodyCell(
                width: 88,
                child: _LevelPill(level: entry.level, color: levelColor),
              ),
              Expanded(
                child: _BodyCell(
                  child: Text(
                    entry.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: levelColor,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              _BodyCell(
                width: 88,
                child: Text(
                  _formatClock(entry.receivedAt),
                  style: TextStyle(
                    color: colors.muted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMessageDialog(BuildContext context) async {
    final colors = _LogViewerColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        return AlertDialog(
          title: Text('日志 message #${entry.lineNumber}'),
          content: SizedBox(
            width: math.min(820, size.width - 72),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height * 0.62),
              child: SingleChildScrollView(
                child: SelectableText(
                  entry.text,
                  style: TextStyle(
                    color: colors.text,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: entry.text));
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已复制当前 message')));
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('复制'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Color _levelColor(_LogLevel level, _LogViewerColors colors) {
    return switch (level) {
      _LogLevel.error => colors.error,
      _LogLevel.warning => colors.warning,
      _LogLevel.info => colors.text,
    };
  }
}

class _BodyCell extends StatelessWidget {
  const _BodyCell({
    required this.child,
    this.width,
    this.align = Alignment.centerLeft,
  });

  final Widget child;
  final double? width;
  final Alignment align;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: align,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: child,
    );
    if (width == null) return content;
    return SizedBox(width: width, child: content);
  }
}

class _LevelPill extends StatelessWidget {
  const _LevelPill({required this.level, required this.color});

  final _LogLevel level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: level == _LogLevel.info ? 0.08 : 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        switch (level) {
          _LogLevel.error => 'error',
          _LogLevel.warning => 'warn',
          _LogLevel.info => 'info',
        },
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _NetworkStatusBar extends StatelessWidget {
  const _NetworkStatusBar({
    required this.totalCount,
    required this.visibleCount,
    required this.lastReceivedAt,
    required this.lastError,
    required this.startOffset,
  });

  final int totalCount;
  final int visibleCount;
  final DateTime? lastReceivedAt;
  final Object? lastError;
  final int startOffset;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    final statusText = lastError == null
        ? 'Rows: $visibleCount / $totalCount · Offset: $startOffset'
        : '日志拉取失败，正在重试 · ${lastError.toString()}';
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.toolbar,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            lastError == null ? Icons.circle : Icons.error_rounded,
            size: 8,
            color: lastError == null ? colors.success : colors.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: lastError == null ? colors.muted : colors.error,
                fontSize: 11,
              ),
            ),
          ),
          if (lastReceivedAt != null)
            Text(
              'Last: ${_formatClock(lastReceivedAt!)}',
              style: TextStyle(color: colors.muted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _EmptyLogState extends StatelessWidget {
  const _EmptyLogState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = _LogViewerColors.of(context);
    return Text(text, style: TextStyle(color: colors.muted, fontSize: 12));
  }
}

String _formatClock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
