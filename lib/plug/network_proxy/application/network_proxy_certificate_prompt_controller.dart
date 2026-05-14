import '../network_proxy.dart';

class NetworkProxyCertificatePromptController {
  const NetworkProxyCertificatePromptController();

  bool shouldProbe(NetworkProxyState state) => state.shouldUseClientProxy;

  Future<ProxyCertificateProbeResult> probe(NetworkProxyState state) {
    return probeProxyCertificateStatus(state);
  }

  bool shouldPrompt(ProxyCertificateProbeResult result) {
    return result.certificateRequired && !result.certificateTrusted;
  }

  String? installUrlFromState(NetworkProxyState state) {
    final proxy = state.client;
    if (!proxy.isConfigured) return null;
    final scheme = proxy.encrypted ? 'https' : 'http';
    return '$scheme://${proxy.host}:${proxy.port}/__proxy/cert';
  }
}
