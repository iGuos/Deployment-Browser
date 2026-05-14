/// 网络代理插件公共导出（无业务依赖）。
///
/// 默认导出纯 Dart 状态、配置、codec、证书探测 facade 与 network event。
/// IO-only 能力请按需单独 import `core/http_forward_proxy_server.dart`、
/// `core/http_client_proxy_apply.dart` 或 `core/mitm_certificate_manager.dart`。
library;

export 'core/network_proxy_state.dart';
export 'core/network_proxy_state_codec.dart';
export 'core/proxy_certificate_probe.dart';
export 'core/proxy_certificate_probe_result.dart';
export 'core/proxy_client_config.dart';
export 'core/proxy_network_event.dart';
export 'core/proxy_role.dart';
export 'core/proxy_server_config.dart';
