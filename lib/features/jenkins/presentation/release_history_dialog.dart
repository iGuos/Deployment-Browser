import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../data/jenkins_repository.dart';
import '../domain/jenkins_build.dart';

Future<void> showReleaseHistoryDialog({
  required BuildContext context,
  required String jenkinsAccountId,
  required String jobFullName,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => ReleaseHistoryDialog(
      accountId: jenkinsAccountId,
      jobFullName: jobFullName,
    ),
  );
}

class ReleaseHistoryDialog extends ConsumerStatefulWidget {
  const ReleaseHistoryDialog({
    super.key,
    required this.accountId,
    required this.jobFullName,
  });

  final String accountId;
  final String jobFullName;

  @override
  ConsumerState<ReleaseHistoryDialog> createState() => _ReleaseHistoryDialogState();
}

class _ReleaseHistoryDialogState extends ConsumerState<ReleaseHistoryDialog> {
  Future<List<JenkinsReleaseHistoryRow>>? _future;
  var _depsLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_depsLoaded) return;
    _depsLoaded = true;
    _reload();
  }

  void _reload() {
    final repo = ref.read(jenkinsRepositoryForAccountProvider(widget.accountId));
    setState(() {
      _future = repo == null
          ? Future.error(StateError('no repository'))
          : repo.fetchReleaseHistory(widget.jobFullName);
    });
  }

  String _resultLabel(AppL10n l10n, BuildResult r) {
    return switch (r) {
      BuildResult.success => l10n.buildSuccess,
      BuildResult.failure => l10n.buildFailed,
      BuildResult.unstable => l10n.buildUnstable,
      BuildResult.aborted => l10n.buildAborted,
      BuildResult.notBuilt => l10n.buildIdle,
      BuildResult.running => l10n.buildRunning,
      BuildResult.unknown => '—',
    };
  }

  Color _resultColor(AppPalette palette, BuildResult r) {
    return switch (r) {
      BuildResult.success => palette.success,
      BuildResult.failure => palette.danger,
      BuildResult.unstable => palette.warning,
      BuildResult.aborted => palette.muted,
      BuildResult.running => palette.running,
      BuildResult.notBuilt || BuildResult.unknown => palette.muted,
    };
  }

  String _timeLabel(BuildContext context, JenkinsBuild b) {
    if (b.timestamp <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(b.timestamp);
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMd(locale).add_Hm().format(dt);
  }

  String _durationLabel(JenkinsBuild b) {
    if (b.building) return '…';
    final ms = b.duration;
    if (ms <= 0) return '—';
    final d = Duration(milliseconds: ms);
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  String _releaseMetaLine(AppL10n l10n, JenkinsReleaseHistoryRow row) {
    final who = row.releasedBy?.trim();
    final sha = row.gitRevision?.trim();
    final whoDisp = (who != null && who.isNotEmpty) ? who : '—';
    final gitDisp = (sha != null && sha.isNotEmpty) ? _abbreviateGitSha(sha) : '—';
    return '${l10n.projectReleaseHistoryReleasedBy} $whoDisp · ${l10n.projectReleaseHistoryGitRevision} $gitDisp';
  }

  String _abbreviateGitSha(String full) {
    if (full.length <= 12) return full;
    return full.substring(0, 12);
  }

  String _paramsPreview(Map<String, String> params) {
    if (params.isEmpty) return '';
    final parts = params.entries.take(6).map((e) {
      final v = e.value;
      final short = v.length > 48 ? '${v.substring(0, 45)}…' : v;
      return '${e.key}: $short';
    });
    return parts.join(' · ');
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final palette = context.palette;

    return AlertDialog(
      title: Text(l10n.projectReleaseHistoryTitle),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<JenkinsReleaseHistoryRow>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              // 勿用会撑满 AlertDialog content 的 [Center]，否则先出现整片空白再缩高，观感很差。
              return const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.2)),
              );
            }
            if (snap.hasError) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.projectReleaseHistoryError('${snap.error}'),
                    style: TextStyle(color: palette.danger, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(l10n.projectReleaseHistoryRetry),
                  ),
                ],
              );
            }
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  l10n.projectReleaseHistoryEmpty,
                  style: TextStyle(color: palette.muted, fontSize: 13),
                ),
              );
            }
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Scrollbar(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => Divider(height: 1, color: palette.borderSubtle),
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final b = row.build;
                    final r = b.resultEnum;
                    final preview = _paramsPreview(row.parameters);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(top: 5, right: 10),
                                decoration: BoxDecoration(
                                  color: _resultColor(palette, r),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          '${l10n.buildNumber} ${b.number}',
                                          style: TextStyle(
                                            color: palette.text,
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _resultLabel(l10n, r),
                                          style: TextStyle(
                                            color: _resultColor(palette, r),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${l10n.buildStarted} ${_timeLabel(context, b)} · ${l10n.buildDuration} ${_durationLabel(b)}',
                                      style: TextStyle(color: palette.muted, fontSize: 11.5),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _releaseMetaLine(l10n, row),
                                      style: TextStyle(color: palette.muted, fontSize: 11.5),
                                    ),
                                    if (preview.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        preview,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: palette.text, fontSize: 11.5, height: 1.35),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (b.url.isNotEmpty)
                                IconButton(
                                  tooltip: l10n.projectReleaseHistoryOpen,
                                  icon: Icon(Icons.open_in_new_rounded, size: 18, color: palette.accent),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _openUrl(b.url),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}
