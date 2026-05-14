import 'network_proxy_state.dart';
import 'proxy_certificate_probe_result.dart';

Future<ProxyCertificateProbeResult> probeProxyCertificateStatus(
  NetworkProxyState state,
) async {
  return const ProxyCertificateProbeResult(
    proxyReachable: false,
    certificateRequired: false,
    certificateTrusted: true,
    installUrl: null,
  );
}
