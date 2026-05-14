enum ProxyNetworkEventKind { started, updated, completed, failed }

const proxyNetworkPhaseMitmClientCertificateRequired =
    'mitm_client_certificate_required';

class ProxyNetworkEvent {
  const ProxyNetworkEvent({required this.kind, required this.entry});

  final ProxyNetworkEventKind kind;
  final ProxyNetworkEntry entry;

  Map<String, Object?> toJson() => {'kind': kind.name, 'entry': entry.toJson()};

  static ProxyNetworkEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kindRaw = raw['kind']?.toString();
    final kind = ProxyNetworkEventKind.values
        .where((v) => v.name == kindRaw)
        .firstOrNull;
    final entry = ProxyNetworkEntry.fromJson(raw['entry']);
    if (kind == null || entry == null) return null;
    return ProxyNetworkEvent(kind: kind, entry: entry);
  }
}

class ProxyNetworkEntry {
  const ProxyNetworkEntry({
    required this.id,
    required this.startedAtMs,
    required this.method,
    required this.url,
    required this.host,
    required this.path,
    required this.protocol,
    required this.type,
    required this.status,
    required this.statusText,
    required this.durationMs,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.requestBodyPreview,
    required this.responseBodyPreview,
    required this.bytesSent,
    required this.bytesReceived,
    required this.remoteAddress,
    required this.upstreamAddress,
    required this.error,
    required this.phase,
  });

  final String id;
  final int startedAtMs;
  final String method;
  final String url;
  final String host;
  final String path;
  final String protocol;
  final String type;
  final int? status;
  final String statusText;
  final int? durationMs;
  final List<ProxyHeader> requestHeaders;
  final List<ProxyHeader> responseHeaders;
  final String requestBodyPreview;
  final String responseBodyPreview;
  final int bytesSent;
  final int bytesReceived;
  final String remoteAddress;
  final String upstreamAddress;
  final String error;
  final String phase;

  ProxyNetworkEntry copyWith({
    int? status,
    String? statusText,
    int? durationMs,
    List<ProxyHeader>? requestHeaders,
    List<ProxyHeader>? responseHeaders,
    String? requestBodyPreview,
    String? responseBodyPreview,
    int? bytesSent,
    int? bytesReceived,
    String? upstreamAddress,
    String? error,
    String? phase,
  }) {
    return ProxyNetworkEntry(
      id: id,
      startedAtMs: startedAtMs,
      method: method,
      url: url,
      host: host,
      path: path,
      protocol: protocol,
      type: type,
      status: status ?? this.status,
      statusText: statusText ?? this.statusText,
      durationMs: durationMs ?? this.durationMs,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      responseHeaders: responseHeaders ?? this.responseHeaders,
      requestBodyPreview: requestBodyPreview ?? this.requestBodyPreview,
      responseBodyPreview: responseBodyPreview ?? this.responseBodyPreview,
      bytesSent: bytesSent ?? this.bytesSent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      remoteAddress: remoteAddress,
      upstreamAddress: upstreamAddress ?? this.upstreamAddress,
      error: error ?? this.error,
      phase: phase ?? this.phase,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'startedAtMs': startedAtMs,
    'method': method,
    'url': url,
    'host': host,
    'path': path,
    'protocol': protocol,
    'type': type,
    'status': status,
    'statusText': statusText,
    'durationMs': durationMs,
    'requestHeaders': requestHeaders.map((h) => h.toJson()).toList(),
    'responseHeaders': responseHeaders.map((h) => h.toJson()).toList(),
    'requestBodyPreview': requestBodyPreview,
    'responseBodyPreview': responseBodyPreview,
    'bytesSent': bytesSent,
    'bytesReceived': bytesReceived,
    'remoteAddress': remoteAddress,
    'upstreamAddress': upstreamAddress,
    'error': error,
    'phase': phase,
  };

  static ProxyNetworkEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ProxyNetworkEntry(
      id: raw['id']?.toString() ?? '',
      startedAtMs: (raw['startedAtMs'] as num?)?.toInt() ?? 0,
      method: raw['method']?.toString() ?? '',
      url: raw['url']?.toString() ?? '',
      host: raw['host']?.toString() ?? '',
      path: raw['path']?.toString() ?? '',
      protocol: raw['protocol']?.toString() ?? '',
      type: raw['type']?.toString() ?? '',
      status: (raw['status'] as num?)?.toInt(),
      statusText: raw['statusText']?.toString() ?? '',
      durationMs: (raw['durationMs'] as num?)?.toInt(),
      requestHeaders: _headersFromJson(raw['requestHeaders']),
      responseHeaders: _headersFromJson(raw['responseHeaders']),
      requestBodyPreview: raw['requestBodyPreview']?.toString() ?? '',
      responseBodyPreview: raw['responseBodyPreview']?.toString() ?? '',
      bytesSent: (raw['bytesSent'] as num?)?.toInt() ?? 0,
      bytesReceived: (raw['bytesReceived'] as num?)?.toInt() ?? 0,
      remoteAddress: raw['remoteAddress']?.toString() ?? '',
      upstreamAddress: raw['upstreamAddress']?.toString() ?? '',
      error: raw['error']?.toString() ?? '',
      phase: raw['phase']?.toString() ?? '',
    );
  }

  static List<ProxyHeader> _headersFromJson(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(ProxyHeader.fromJson)
        .whereType<ProxyHeader>()
        .toList(growable: false);
  }
}

class ProxyHeader {
  const ProxyHeader({required this.name, required this.value});

  final String name;
  final String value;

  Map<String, Object?> toJson() => {'name': name, 'value': value};

  static ProxyHeader? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ProxyHeader(
      name: raw['name']?.toString() ?? '',
      value: raw['value']?.toString() ?? '',
    );
  }
}
