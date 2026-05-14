import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/proxy_network_event.dart';

const proxyNetworkTypeFilters = [
  'All',
  'Fetch/XHR',
  'Doc',
  'CSS',
  'JS',
  'Font',
  'Img',
  'Media',
  'Manifest',
  'Socket',
  'Wasm',
  'Other',
];

String proxyNetworkDevToolsType(ProxyNetworkEntry entry) {
  final method = entry.method.toUpperCase();
  final path = _pathWithoutQuery(
    entry.path.isNotEmpty ? entry.path : entry.url,
  ).toLowerCase();
  final contentType = _headerValue(
    entry.responseHeaders,
    'content-type',
  ).toLowerCase();
  final accept = _headerValue(entry.requestHeaders, 'accept').toLowerCase();

  if (entry.type == 'tunnel' || method == 'CONNECT') return 'Socket';
  if (entry.type == 'log') return 'Other';

  if (_hasExt(path, const ['.css']) || contentType.contains('text/css')) {
    return 'CSS';
  }
  if (_hasExt(path, const ['.js', '.mjs', '.cjs']) ||
      contentType.contains('javascript') ||
      contentType.contains('ecmascript')) {
    return 'JS';
  }
  if (_hasExt(path, const [
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.webp',
        '.svg',
        '.ico',
        '.avif',
        '.bmp',
      ]) ||
      contentType.startsWith('image/')) {
    return 'Img';
  }
  if (_hasExt(path, const ['.woff', '.woff2', '.ttf', '.otf', '.eot']) ||
      contentType.startsWith('font/') ||
      contentType.contains('application/font')) {
    return 'Font';
  }
  if (_hasExt(path, const [
        '.mp4',
        '.webm',
        '.mp3',
        '.m4a',
        '.ogg',
        '.wav',
        '.mov',
      ]) ||
      contentType.startsWith('audio/') ||
      contentType.startsWith('video/')) {
    return 'Media';
  }
  if (_hasExt(path, const ['.webmanifest', '.manifest']) ||
      contentType.contains('manifest')) {
    return 'Manifest';
  }
  if (_hasExt(path, const ['.wasm']) ||
      contentType.contains('application/wasm')) {
    return 'Wasm';
  }
  if (_hasExt(path, const ['.html', '.htm']) ||
      contentType.contains('text/html') ||
      accept.contains('text/html')) {
    return 'Doc';
  }
  if (method != 'GET' ||
      contentType.contains('json') ||
      contentType.contains('xml') ||
      contentType.contains('event-stream') ||
      accept.contains('json')) {
    return 'Fetch/XHR';
  }
  return 'Other';
}

String _pathWithoutQuery(String path) {
  final query = path.indexOf('?');
  return query < 0 ? path : path.substring(0, query);
}

bool _hasExt(String path, List<String> extensions) {
  return extensions.any(path.endsWith);
}

String _headerValue(List<ProxyHeader> headers, String name) {
  final lower = name.toLowerCase();
  for (final h in headers) {
    if (h.name.toLowerCase() == lower) return h.value;
  }
  return '';
}

/// 内置转发代理的实时日志行（由 [registerNetworkProxyEmbeddedServer] 的 [onLog] 写入）。
///
/// 主窗口与主进程内嵌对话框共用同一 [ProviderScope]，可直接收到行。
/// 桌面独立「代理设置」子窗口由 [tryBroadcastEmbeddedProxyLogLine] 跨引擎投递（见 [registerEmbeddedProxyLogCrossWindowReceiver]）。
class EmbeddedProxyRequestLogState {
  const EmbeddedProxyRequestLogState({
    this.entries = const [],
    this.selectedId,
    this.query = '',
    this.typeFilter = 'All',
    this.preserveLog = true,
    this.recording = true,
  });

  final List<ProxyNetworkEntry> entries;
  final String? selectedId;
  final String query;
  final String typeFilter;
  final bool preserveLog;
  final bool recording;

  ProxyNetworkEntry? get selectedEntry {
    final id = selectedId;
    if (id == null) return entries.firstOrNull;
    return entries.where((e) => e.id == id).firstOrNull;
  }

  List<ProxyNetworkEntry> get filteredEntries {
    final q = query.trim().toLowerCase();
    return entries
        .where((e) {
          // Network 表只展示结构化请求；SESSION/listening 等内部日志不应占用 Name 列。
          if (e.type == 'log') return false;
          if (!_matchesTypeFilter(e, typeFilter)) return false;
          if (q.isEmpty) return true;
          return e.url.toLowerCase().contains(q) ||
              e.method.toLowerCase().contains(q) ||
              e.statusText.toLowerCase().contains(q) ||
              e.host.toLowerCase().contains(q);
        })
        .toList(growable: false);
  }

  EmbeddedProxyRequestLogState copyWith({
    List<ProxyNetworkEntry>? entries,
    String? selectedId,
    bool clearSelectedId = false,
    String? query,
    String? typeFilter,
    bool? preserveLog,
    bool? recording,
  }) {
    return EmbeddedProxyRequestLogState(
      entries: entries ?? this.entries,
      selectedId: clearSelectedId ? null : selectedId ?? this.selectedId,
      query: query ?? this.query,
      typeFilter: typeFilter ?? this.typeFilter,
      preserveLog: preserveLog ?? this.preserveLog,
      recording: recording ?? this.recording,
    );
  }

  static bool _matchesTypeFilter(ProxyNetworkEntry entry, String filter) {
    if (filter == 'All') return true;
    return proxyNetworkDevToolsType(entry) == filter;
  }
}

class EmbeddedProxyRequestLogNotifier
    extends Notifier<EmbeddedProxyRequestLogState> {
  static const int _maxLines = 500;

  @override
  EmbeddedProxyRequestLogState build() => const EmbeddedProxyRequestLogState();

  void addLine(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final entry = ProxyNetworkEntry(
      id: 'log-${DateTime.now().microsecondsSinceEpoch}',
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      method: 'LOG',
      url: line,
      host: '',
      path: line,
      protocol: '',
      type: 'log',
      status: null,
      statusText: '',
      durationMs: null,
      requestHeaders: const [],
      responseHeaders: const [],
      requestBodyPreview: '',
      responseBodyPreview: '$ts  $line',
      bytesSent: 0,
      bytesReceived: 0,
      remoteAddress: '',
      upstreamAddress: '',
      error: '',
      phase: 'log',
    );
    _upsert(entry);
  }

  void applyEvent(ProxyNetworkEvent event) {
    if (!state.recording) return;
    _upsert(event.entry);
  }

  void _upsert(ProxyNetworkEntry entry) {
    final cur = state.entries;
    final index = cur.indexWhere((e) => e.id == entry.id);
    final next = [...cur];
    if (index >= 0) {
      next[index] = entry;
    } else {
      next.add(entry);
    }
    if (next.length > _maxLines) {
      state = state.copyWith(entries: next.sublist(next.length - _maxLines));
    } else {
      state = state.copyWith(entries: next);
    }
  }

  void select(String? id) {
    state = state.copyWith(selectedId: id, clearSelectedId: id == null);
  }

  void setQuery(String query) {
    state = state.copyWith(query: query);
  }

  void setTypeFilter(String type) {
    state = state.copyWith(typeFilter: type);
  }

  void setRecording(bool recording) {
    state = state.copyWith(recording: recording);
  }

  void setPreserveLog(bool preserveLog) {
    state = state.copyWith(preserveLog: preserveLog);
  }

  void clear() {
    state = state.copyWith(entries: const [], clearSelectedId: true);
  }
}

final embeddedProxyRequestLogProvider =
    NotifierProvider<
      EmbeddedProxyRequestLogNotifier,
      EmbeddedProxyRequestLogState
    >(EmbeddedProxyRequestLogNotifier.new);
