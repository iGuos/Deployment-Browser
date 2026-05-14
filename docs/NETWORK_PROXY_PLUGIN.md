# 网络代理插件说明

本说明记录 **与具体业务（如 Jenkins）无关** 的网络代理模块设计；可拷贝 `lib/plug/network_proxy` 到其它工程复用。

## 角色说明

| 模式 | 含义 | 本仓库实现 |
|------|------|------------|
| **服务端** | 本机作为 **HTTP 转发代理** 监听端口，为其它客户端转发流量（CONNECT / 基础 `http://` 绝对 URI），可选择 TLS 加密或明文模式。 | 应用内 **`HttpForwardProxyServer`**（`dart:io`），仅 **主窗口进程** 按配置启动/停止监听；独立「代理设置」窗口只写持久化；启动监听必须配置用户名和密码，使用 Proxy Basic 认证。 |
| **客户端** | 本工具作为 **HTTP 客户端**，按配置的 `host:port` 与加密/明文模式连接上游代理，再经 **HTTP CONNECT**（HTTPS 目标）等方式转发请求。 | 通过 `dart:io` `HttpClient.findProxy` + `connectionFactory` 接入 Dio（见 `lib/core/http/jenkins_proxy_adapter_io.dart`）。 |

## 公共 API（`lib/plug/network_proxy/`）

- **`NetworkProxyRole`**：`server` / `client`。
- **`ProxyClientConfig`**：客户端代理参数（启用、`encrypted` 加密/明文模式、主机、端口、可选 Basic 认证、`noProxy` 主机列表）。
- **`ProxyServerConfig`**：内置服务端（`encrypted` 加密/明文模式、`listeningEnabled` 是否启动监听、`listenOnLoopbackOnly`、端口 `0` 表示未填、访问用户名和密码）。
- **`NetworkProxyState`**：`role` + `client` + `server`，为唯一持久化模型。
- **`NetworkProxyStateCodec`**：`encode` / `decode` JSON 字符串，**不含** SharedPreferences / Flutter。
- **`applyProxyClientToHttpClient`**：将 `ProxyClientConfig` 应用到 `dart:io` `HttpClient`（`findProxy` / `connectionFactory` / `authenticateProxy`）。
- **`HttpForwardProxyServer`**（单独 import，依赖 `dart:io`）：极简转发代理；**不要**从同时面向 Web 的总 barrel 再导出，以免 Web 编译拉入 `dart:io`。

**禁止**在 `lib/plug` 中引用 Jenkins、Riverpod、Dio、项目内 `features/` 等；除 `HttpForwardProxyServer` 外仅 `meta`（`@immutable`）等基础库 + `dart:convert` 等。

## 与本工程（Deployment）的接入点

1. **持久化键**：`NetworkProxyStateCodec.preferenceKey`（`plug.network_proxy.state_v1`），由设置/代理窗口写入 `SharedPreferences`。
2. **Dio**：`buildJenkinsDio(..., networkProxy: state)` 在非 Web 平台通过 `jenkins_proxy_adapter_io.dart` 挂载 `IOHttpClientAdapter`。
3. **内置服务端**：仅 **主窗口进程** 通过 `registerNetworkProxyEmbeddedServer`（`network_proxy_embedded_server_binding*.dart`）监听 `networkProxyStateProvider`，在 `role == server`、**`server.listeningEnabled`**、**`server.port`** 合法且用户名/密码已填写时 `bind`；约每 2 秒 **先 `SharedPreferences.reload` 再读取** 代理键并比对 JSON，以便 **独立代理窗口**（另一 Flutter 引擎）写入磁盘后主进程能拉起/关闭监听（主进程内存缓存默认不会跨进程失效）。
4. **配置刷新**：主进程在 `AppLifecycleState.resumed` 时异步 `reloadFromDisk`（内部同样 `reload` 再读），以便独立窗口写入后主窗口回到前台时同步代理状态并重建 Jenkins Dio。

## 安全提示

- **「局域网」监听（0.0.0.0）** 时，同网络其它设备可将流量经本机转发；请使用强用户名和密码，并避免在不可信网络开启。
- 加密模式只保护客户端到代理服务端之间的代理协议，客户端仍需要信任内置自签证书（例如 curl 使用 `--proxy-insecure`）。
- 内置代理为 **调试 / 跳板** 用途，生产环境仍建议使用 Squid、企业代理等专业方案。

## 版本与演进

- `state_v1` JSON 增加可选 `server` 对象；旧数据无该字段时解码为 `ProxyServerConfig.defaults`。
- 结构大改时递增版本号与 `Codec` 内常量，并做好迁移说明。
