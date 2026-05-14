import 'network_proxy_state.dart';
import 'proxy_certificate_probe_result.dart';
import 'proxy_certificate_probe_stub.dart'
    if (dart.library.io) 'proxy_certificate_probe_io.dart'
    as impl;

Future<ProxyCertificateProbeResult> probeProxyCertificateStatus(
  NetworkProxyState state,
) => impl.probeProxyCertificateStatus(state);
