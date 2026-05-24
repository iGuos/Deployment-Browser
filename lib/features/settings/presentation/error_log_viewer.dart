import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/error_log_service.dart';
import '../../../l10n/app_localizations.dart';

/// 「设置 → 异常日志」入口：展示运行中收集到的异常并支持清空。
Future<void> showErrorLogViewer(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _ErrorLogViewerDialog(),
  );
}

class _ErrorLogViewerDialog extends StatelessWidget {
  const _ErrorLogViewerDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.bug_report_outlined, color: palette.danger, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.errorLogTitle)),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 480,
        child: ListenableBuilder(
          listenable: errorLogService,
          builder: (ctx, _) {
            final entries = errorLogService.entries;
            if (entries.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      size: 36,
                      color: palette.muted,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.errorLogEmpty,
                      style: TextStyle(color: palette.muted, fontSize: 13),
                    ),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.errorLogCount(entries.length),
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Scrollbar(
                    child: ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 12, color: palette.borderSubtle),
                      itemBuilder: (_, i) => _ErrorLogTile(entry: entries[i]),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.delete_sweep_outlined, size: 16),
          style: TextButton.styleFrom(foregroundColor: palette.danger),
          onPressed: () async {
            final confirmed = await _confirmClear(context, l10n);
            if (!confirmed) return;
            await errorLogService.clear();
          },
          label: Text(l10n.errorLogClear),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }

  Future<bool> _confirmClear(BuildContext context, AppL10n l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.errorLogClearConfirmTitle),
        content: Text(l10n.errorLogClearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.errorLogClear),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _ErrorLogTile extends StatefulWidget {
  const _ErrorLogTile({required this.entry});

  final ErrorLogEntry entry;

  @override
  State<_ErrorLogTile> createState() => _ErrorLogTileState();
}

class _ErrorLogTileState extends State<_ErrorLogTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final levelColor = switch (entry.level) {
      'warning' => palette.warning,
      'fatal' => palette.danger,
      _ => palette.danger,
    };

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: levelColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: levelColor.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    entry.level.toUpperCase(),
                    style: TextStyle(
                      color: levelColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatTimestamp(entry.timestamp),
                    style: TextStyle(color: palette.muted, fontSize: 11.5),
                  ),
                ),
                IconButton(
                  tooltip: l10n.settingsCopyError,
                  onPressed: () => _copy(entry),
                  icon: Icon(
                    Icons.content_copy_rounded,
                    size: 14,
                    color: palette.muted,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  splashRadius: 14,
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: palette.muted,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              entry.message.isEmpty ? '(no message)' : entry.message,
              style: TextStyle(color: palette.text, fontSize: 13, height: 1.4),
            ),
            if (_expanded) ...[
              if (entry.error != null) ...[
                const SizedBox(height: 6),
                _DetailBlock(label: l10n.errorLogException, body: entry.error!),
              ],
              if (entry.stackTrace != null) ...[
                const SizedBox(height: 6),
                _DetailBlock(label: l10n.errorLogStack, body: entry.stackTrace!),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copy(ErrorLogEntry entry) async {
    final buf = StringBuffer()
      ..writeln('[${entry.level.toUpperCase()}] ${_formatTimestamp(entry.timestamp)}')
      ..writeln(entry.message);
    if (entry.error != null) {
      buf
        ..writeln('---')
        ..writeln(entry.error);
    }
    if (entry.stackTrace != null) {
      buf
        ..writeln('---')
        ..writeln(entry.stackTrace);
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppL10n.of(context).settingsCopiedToClipboard),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock({required this.label, required this.body});

  final String label;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            body,
            style: TextStyle(
              color: palette.text,
              fontSize: 11.5,
              height: 1.45,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
