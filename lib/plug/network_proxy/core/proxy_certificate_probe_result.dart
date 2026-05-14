class ProxyCertificateProbeResult {
  const ProxyCertificateProbeResult({
    required this.proxyReachable,
    required this.certificateRequired,
    required this.certificateTrusted,
    required this.installUrl,
    this.status = const {},
    this.error,
  });

  final bool proxyReachable;
  final bool certificateRequired;
  final bool certificateTrusted;
  final String? installUrl;
  final Map<String, Object?> status;
  final Object? error;
}
