import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../core/mitm_certificate_manager.dart';
import '../application/embedded_proxy_log_cross_window_io.dart';
import '../application/embedded_proxy_request_log_provider.dart';
import '../application/network_proxy_state_provider.dart';
import '../network_proxy.dart';

const kNetworkProxyThemeModePreferenceKey = 'app.theme_mode';

ThemeData _defaultNetworkProxyLightTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    useMaterial3: true,
  );
}

ThemeData _defaultNetworkProxyDarkTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );
}

bool _isMobileLayout(BuildContext context) {
  return MediaQuery.sizeOf(context).width < 600;
}

class NetworkProxyPresentationLabels {
  const NetworkProxyPresentationLabels({
    this.settingsProxyMobileJenkinsHint = '移动端通常只需要配置客户端代理；服务端监听适用于桌面端共享代理。',
    this.proxyViewLiveRequestsButton = '查看实时请求',
    this.proxyLiveLogTitle = '代理实时日志',
    this.proxyLiveLogClose = '关闭',
    this.proxyLiveLogClear = '清空日志',
    this.proxyLiveLogEmpty = '暂无代理请求',
    this.settingsSectionProxy = '代理设置',
  });

  final String settingsProxyMobileJenkinsHint;
  final String proxyViewLiveRequestsButton;
  final String proxyLiveLogTitle;
  final String proxyLiveLogClose;
  final String proxyLiveLogClear;
  final String proxyLiveLogEmpty;
  final String settingsSectionProxy;

  static NetworkProxyPresentationLabels of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<NetworkProxyPresentationScope>()
            ?.labels ??
        const NetworkProxyPresentationLabels();
  }
}

class NetworkProxyPresentationScope extends InheritedWidget {
  const NetworkProxyPresentationScope({
    super.key,
    required this.labels,
    required super.child,
  });

  final NetworkProxyPresentationLabels labels;

  @override
  bool updateShouldNotify(NetworkProxyPresentationScope oldWidget) {
    return labels != oldWidget.labels;
  }
}

ThemeMode _themeModeFromPrefs(SharedPreferences prefs) {
  final raw = prefs.getString(kNetworkProxyThemeModePreferenceKey);
  return switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => ThemeMode.dark,
  };
}

const kProxyLiveLogWindowArguments = 'app_proxy_live_log';

/// 独立引擎入口：带 [ProviderScope]，与主窗口共享 `SharedPreferences` 持久化键。
class ProxySettingsStandaloneApp extends StatelessWidget {
  const ProxySettingsStandaloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            themeMode: ThemeMode.system,
            theme: _defaultNetworkProxyLightTheme(),
            darkTheme: _defaultNetworkProxyDarkTheme(),
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return ProviderScope(
          overrides: [
            networkProxySharedPreferencesProvider.overrideWithValue(snap.data!),
          ],
          child: _ProxySettingsMaterialApp(prefs: snap.data!),
        );
      },
    );
  }
}

class _ProxySettingsMaterialApp extends ConsumerStatefulWidget {
  const _ProxySettingsMaterialApp({required this.prefs});

  final SharedPreferences prefs;

  @override
  ConsumerState<_ProxySettingsMaterialApp> createState() =>
      _ProxySettingsMaterialAppState();
}

class _ProxySettingsMaterialAppState
    extends ConsumerState<_ProxySettingsMaterialApp> {
  @override
  void initState() {
    super.initState();
    unawaited(
      registerEmbeddedProxyLogCrossWindowReceiver(
        isMounted: () => mounted,
        ref: ref,
        onUnhandledMethodCall: (call) async {
          if (call.method == 'showAndFocus') {
            await windowManager.show();
            await windowManager.focus();
          }
          return null;
        },
      ),
    );
  }

  @override
  void dispose() {
    unawaited(unregisterEmbeddedProxyLogCrossWindowReceiver());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeModeFromPrefs(widget.prefs),
      theme: _defaultNetworkProxyLightTheme(),
      darkTheme: _defaultNetworkProxyDarkTheme(),
      home: const ProxySettingsFormPage(),
    );
  }
}

/// 独立实时日志窗口入口：只展示日志，不展示代理配置表单。
class ProxyLiveLogStandaloneApp extends StatelessWidget {
  const ProxyLiveLogStandaloneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _defaultNetworkProxyLightTheme(),
            darkTheme: _defaultNetworkProxyDarkTheme(),
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        return ProviderScope(
          overrides: [
            networkProxySharedPreferencesProvider.overrideWithValue(snap.data!),
          ],
          child: _ProxyLiveLogMaterialApp(prefs: snap.data!),
        );
      },
    );
  }
}

class _ProxyLiveLogMaterialApp extends ConsumerStatefulWidget {
  const _ProxyLiveLogMaterialApp({required this.prefs});

  final SharedPreferences prefs;

  @override
  ConsumerState<_ProxyLiveLogMaterialApp> createState() =>
      _ProxyLiveLogMaterialAppState();
}

class _ProxyLiveLogMaterialAppState
    extends ConsumerState<_ProxyLiveLogMaterialApp> {
  @override
  void initState() {
    super.initState();
    unawaited(
      registerEmbeddedProxyLogCrossWindowReceiver(
        isMounted: () => mounted,
        ref: ref,
        onUnhandledMethodCall: (call) async {
          if (call.method == 'showAndFocus') {
            await windowManager.show();
            await windowManager.focus();
          }
          return null;
        },
      ),
    );
  }

  @override
  void dispose() {
    unawaited(unregisterEmbeddedProxyLogCrossWindowReceiver());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeModeFromPrefs(widget.prefs),
      theme: _defaultNetworkProxyLightTheme(),
      darkTheme: _defaultNetworkProxyDarkTheme(),
      home: const _EmbeddedProxyLiveLogWindowPage(),
    );
  }
}

/// 网络代理配置页（中文 UI；与业务无关）。
class ProxySettingsFormPage extends ConsumerStatefulWidget {
  const ProxySettingsFormPage({super.key});

  @override
  ConsumerState<ProxySettingsFormPage> createState() =>
      _ProxySettingsFormPageState();
}

class _ProxySettingsFormPageState extends ConsumerState<ProxySettingsFormPage> {
  late NetworkProxyRole _role;
  late bool _clientEnabled;
  late bool _clientEncrypted;
  late bool _serverBindLoopbackOnly;
  late bool _serverListeningEnabled;
  late bool _serverEncrypted;
  late bool _serverMitmEnabled;
  late bool _serverMitmRemoteClientsEnabled;
  late List<String> _serverProxyAllowHosts;
  late TextEditingController _hostCtrl;
  late TextEditingController _portCtrl;
  late TextEditingController _userCtrl;
  late TextEditingController _passCtrl;
  late TextEditingController _noProxyCtrl;
  late TextEditingController _serverPortCtrl;
  late TextEditingController _serverUserCtrl;
  late TextEditingController _serverPassCtrl;
  final MitmCertificateManager _mitmCertificateManager =
      MitmCertificateManager();
  MitmCertificateState? _mitmCertificateState;
  bool _mitmCertificateBusy = false;
  String? _serverLanAddress;

  /// 客户端「启用代理」开启前正在做可达性探测；期间禁用开关避免重复触发。
  bool _clientProbing = false;

  /// 端口：仅允许数字，最长 5 位。
  static final List<TextInputFormatter> _portFormatters = [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(5),
  ];

  /// 代理主机：仅允许 IP / 域名合法字符（字母、数字、点、连字符），
  /// 从源头挡掉汉字、全角句号「。」、空格等。
  static final List<TextInputFormatter> _hostFormatters = [
    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9.\-]')),
  ];

  /// 用户名 / 密码：仅允许可见 ASCII 字符，挡掉汉字等非 ASCII 输入。
  static final List<TextInputFormatter> _asciiFormatters = [
    FilteringTextInputFormatter.deny(RegExp(r'[^ -~]')),
  ];

  /// 校验主机是否为合法 IPv4 或域名（已被输入过滤限定为 ASCII 字符，这里再做结构校验）。
  static bool _isValidProxyHost(String host) {
    if (host.isEmpty || host.length > 253) return false;
    // 全是数字和点：意图是 IP，必须是合法 IPv4（四段、每段 ≤255），
    // 否则视为写错的 IP（如 192.168.0 / 192.168.0.101.5）。
    if (RegExp(r'^[\d.]+$').hasMatch(host)) {
      final m = RegExp(
        r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
      ).firstMatch(host);
      if (m == null) return false;
      return List.generate(4, (i) => int.parse(m.group(i + 1)!))
          .every((o) => o <= 255);
    }
    // 含字母的域名（含单标签主机名，如 localhost）：每段字母数字开头结尾，可含连字符。
    final hostname = RegExp(
      r'^([A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?))*$',
    );
    return hostname.hasMatch(host);
  }

  Timer? _persistDebounce;

  @override
  void initState() {
    super.initState();
    final s = ref.read(networkProxyStateProvider);
    _hydrate(s);
    _hostCtrl.addListener(_onDebouncedFieldChanged);
    _portCtrl.addListener(_onDebouncedFieldChanged);
    _userCtrl.addListener(_onDebouncedFieldChanged);
    _passCtrl.addListener(_onDebouncedFieldChanged);
    _noProxyCtrl.addListener(_onDebouncedFieldChanged);
    _serverPortCtrl.addListener(_onDebouncedFieldChanged);
    _serverUserCtrl.addListener(_onDebouncedFieldChanged);
    _serverPassCtrl.addListener(_onDebouncedFieldChanged);
    unawaited(_refreshMitmCertificateState());
    unawaited(_refreshServerLanAddress());
  }

  Future<void> _refreshServerLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          if (!mounted) return;
          setState(() => _serverLanAddress = address.address);
          return;
        }
      }
    } catch (_) {
      // 展示入口时降级为占位 IP，避免影响代理配置页。
    }
  }

  void _hydrate(NetworkProxyState s) {
    _role = s.role;
    _clientEnabled = s.client.enabled;
    _clientEncrypted = s.client.encrypted;
    _serverBindLoopbackOnly = s.server.listenOnLoopbackOnly;
    _serverListeningEnabled = s.server.listeningEnabled;
    _serverEncrypted = s.server.encrypted;
    _serverMitmEnabled = s.server.mitmEnabled;
    _serverMitmRemoteClientsEnabled = s.server.mitmRemoteClientsEnabled;
    _serverProxyAllowHosts = s.server.proxyAllowHosts;
    _hostCtrl = TextEditingController(text: s.client.host);
    _portCtrl = TextEditingController(
      text: s.client.port > 0 ? s.client.port.toString() : '',
    );
    _userCtrl = TextEditingController(text: s.client.username);
    _passCtrl = TextEditingController(text: s.client.password);
    _noProxyCtrl = TextEditingController(
      text: s.client.noProxyHosts.join(', '),
    );
    _serverPortCtrl = TextEditingController(
      text: s.server.port > 0 ? s.server.port.toString() : '',
    );
    _serverUserCtrl = TextEditingController(text: s.server.username);
    _serverPassCtrl = TextEditingController(text: s.server.password);
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    _hostCtrl.removeListener(_onDebouncedFieldChanged);
    _portCtrl.removeListener(_onDebouncedFieldChanged);
    _userCtrl.removeListener(_onDebouncedFieldChanged);
    _passCtrl.removeListener(_onDebouncedFieldChanged);
    _noProxyCtrl.removeListener(_onDebouncedFieldChanged);
    _serverPortCtrl.removeListener(_onDebouncedFieldChanged);
    _serverUserCtrl.removeListener(_onDebouncedFieldChanged);
    _serverPassCtrl.removeListener(_onDebouncedFieldChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _noProxyCtrl.dispose();
    _serverPortCtrl.dispose();
    _serverUserCtrl.dispose();
    _serverPassCtrl.dispose();
    super.dispose();
  }

  void _onDebouncedFieldChanged() {
    if (_role == NetworkProxyRole.server &&
        _serverListeningEnabled &&
        (!_serverHasRequiredAuth || _parseServerPortField() <= 0)) {
      setState(() => _serverListeningEnabled = false);
    }
    // 客户端：主机或端口被清空时自动关闭「启用代理」，保持开关与可用性一致。
    if (_role == NetworkProxyRole.client &&
        _clientEnabled &&
        (_hostCtrl.text.trim().isEmpty || _parseClientPortField() <= 0)) {
      setState(() => _clientEnabled = false);
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      unawaited(_persistCurrentRoleSnapshot());
    });
  }

  Future<void> _persistCurrentRoleSnapshot() async {
    if (_role == NetworkProxyRole.server) {
      await _persistServerSnapshot();
    } else {
      await _persistClientSnapshot();
    }
  }

  int _parseServerPortField() {
    final trimmed = _serverPortCtrl.text.trim();
    final parsed = int.tryParse(trimmed);
    if (trimmed.isEmpty || parsed == null || parsed < 1) {
      return 0;
    }
    return parsed > 65535 ? 65535 : parsed;
  }

  String get _mitmCertificatePortalUrl {
    final host = _serverBindLoopbackOnly
        ? '127.0.0.1'
        : (_serverLanAddress ?? '<本机局域网IP>');
    final port = _parseServerPortField();
    final portLabel = port > 0 ? port.toString() : '<端口>';
    final scheme = _serverEncrypted ? 'https' : 'http';
    return '$scheme://$host:$portLabel/__proxy/cert';
  }

  bool get _serverHasRequiredAuth =>
      _serverUserCtrl.text.trim().isNotEmpty && _serverPassCtrl.text.isNotEmpty;

  ProxyServerConfig _buildServerConfigFromForm() {
    return ProxyServerConfig(
      listenOnLoopbackOnly: _serverBindLoopbackOnly,
      port: _parseServerPortField(),
      listeningEnabled: _serverListeningEnabled && _serverHasRequiredAuth,
      encrypted: _serverEncrypted,
      mitmEnabled: _serverMitmEnabled,
      mitmRemoteClientsEnabled: _serverMitmRemoteClientsEnabled,
      proxyAllowHosts: _serverProxyAllowHosts,
      username: _serverUserCtrl.text.trim(),
      password: _serverPassCtrl.text,
    );
  }

  /// 服务端模式下将当前表单中的服务端配置写入磁盘（含「启动监听」开关）。
  Future<void> _persistServerSnapshot() async {
    if (_role != NetworkProxyRole.server) return;
    final client = ref.read(networkProxyStateProvider).client;
    final next = NetworkProxyState(
      role: NetworkProxyRole.server,
      client: client,
      server: _buildServerConfigFromForm(),
    );
    await ref.read(networkProxyStateProvider.notifier).persist(next);
  }

  Future<void> _onServerListeningToggled(bool enabled) async {
    if (_role != NetworkProxyRole.server) return;
    if (enabled && !_serverHasRequiredAuth) {
      setState(() => _serverListeningEnabled = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写访问用户名和访问密码')));
      return;
    }
    if (enabled && _parseServerPortField() <= 0) {
      setState(() => _serverListeningEnabled = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写监听端口')));
      return;
    }
    final previous = _serverListeningEnabled;
    setState(() => _serverListeningEnabled = enabled);
    try {
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverListeningEnabled = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _onServerBindChanged(bool bindLoopbackOnly) async {
    if (_role != NetworkProxyRole.server) return;
    final previous = _serverBindLoopbackOnly;
    setState(() => _serverBindLoopbackOnly = bindLoopbackOnly);
    try {
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverBindLoopbackOnly = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _onServerEncryptedChanged(bool encrypted) async {
    if (_role != NetworkProxyRole.server) return;
    final previous = _serverEncrypted;
    setState(() => _serverEncrypted = encrypted);
    try {
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverEncrypted = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _onServerMitmChanged(bool enabled) async {
    if (_role != NetworkProxyRole.server) return;
    final previous = _serverMitmEnabled;
    setState(() => _serverMitmEnabled = enabled);
    try {
      if (enabled) {
        await _mitmCertificateManager.ensureRootCertificate();
        await _refreshMitmCertificateState(showErrors: true);
      }
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverMitmEnabled = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _onServerMitmRemoteClientsChanged(bool enabled) async {
    if (_role != NetworkProxyRole.server) return;
    final previous = _serverMitmRemoteClientsEnabled;
    setState(() => _serverMitmRemoteClientsEnabled = enabled);
    try {
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverMitmRemoteClientsEnabled = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _openServerProxyAllowlistDialog() async {
    if (_role != NetworkProxyRole.server) return;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ProxyAllowlistDialog(
        initialValue: _serverProxyAllowHosts.join(', '),
      ),
    );
    if (result == null) return;
    final previous = _serverProxyAllowHosts;
    final next = ProxyServerConfig.parseProxyAllowHosts(result);
    setState(() => _serverProxyAllowHosts = next);
    try {
      await _persistServerSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _serverProxyAllowHosts = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _refreshMitmCertificateState({bool showErrors = false}) async {
    if (!mounted) return;
    setState(() => _mitmCertificateBusy = true);
    try {
      final state = await _mitmCertificateManager.inspect();
      if (!mounted) return;
      setState(() {
        _mitmCertificateState = state;
        _mitmCertificateBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _mitmCertificateBusy = false);
      if (showErrors) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('证书状态读取失败：$e')));
      }
    }
  }

  Future<void> _exportMitmRootCertificate() async {
    setState(() => _mitmCertificateBusy = true);
    try {
      final pem = await _mitmCertificateManager.rootCertificatePem();
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Certificate', extensions: ['pem', 'crt']),
        ],
        suggestedName: 'deployment-mitm-root-ca.pem',
      );
      if (location == null) return;
      await File(location.path).writeAsString(pem);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出到 ${location.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出证书失败：$e')));
    } finally {
      if (mounted) {
        setState(() => _mitmCertificateBusy = false);
        await _refreshMitmCertificateState();
      }
    }
  }

  Future<void> _installMitmRootCertificateOnMacOS() async {
    setState(() => _mitmCertificateBusy = true);
    try {
      await _mitmCertificateManager.installRootCertificateOnMacOS();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已请求安装并信任根证书')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('自动信任失败：$e')));
    } finally {
      if (mounted) {
        setState(() => _mitmCertificateBusy = false);
        await _refreshMitmCertificateState();
      }
    }
  }

  Future<void> _openMitmCertificatePortal() async {
    final installUrl = _mitmCertificatePortalUrl;
    final uri = Uri.tryParse(installUrl);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        installUrl.contains('<')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写有效的监听地址和端口')));
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开证书安装页')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开证书安装页失败：$e')));
    }
  }

  Future<void> _openMitmCertificateFolder(String certificatePath) async {
    final path = certificatePath.trim();
    if (path.isEmpty) return;
    try {
      final exitCode = await _revealPathInFileManager(path);
      if (!mounted) return;
      if (exitCode != 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开证书所在文件夹')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开证书所在文件夹失败：$e')));
    }
  }

  int _parseClientPortField() {
    final trimmedPort = _portCtrl.text.trim();
    final parsed = int.tryParse(trimmedPort);
    if (trimmedPort.isEmpty || parsed == null || parsed < 1) {
      return 0;
    }
    return parsed > 65535 ? 65535 : parsed;
  }

  ProxyClientConfig _buildClientConfigFromForm() {
    return ProxyClientConfig(
      enabled: _clientEnabled,
      encrypted: _clientEncrypted,
      host: _hostCtrl.text.trim(),
      port: _parseClientPortField(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      noProxyHosts: ProxyClientConfig.parseNoProxyList(_noProxyCtrl.text),
    );
  }

  Future<void> _persistClientSnapshot() async {
    if (_role != NetworkProxyRole.client) return;
    final server = ref.read(networkProxyStateProvider).server;
    final next = NetworkProxyState(
      role: NetworkProxyRole.client,
      client: _buildClientConfigFromForm(),
      server: server,
    );
    await ref.read(networkProxyStateProvider.notifier).persist(next);
  }

  Future<void> _onClientEnabledToggled(bool enabled) async {
    if (_role != NetworkProxyRole.client || _clientProbing) return;

    // 关闭：直接写入，无需校验。
    if (!enabled) {
      final previous = _clientEnabled;
      setState(() => _clientEnabled = false);
      try {
        await _persistClientSnapshot();
      } catch (e) {
        if (!mounted) return;
        setState(() => _clientEnabled = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
      }
      return;
    }

    // 开启前置校验：必须填了主机和端口。
    final host = _hostCtrl.text.trim();
    final port = _parseClientPortField();
    if (host.isEmpty || port <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写代理主机和端口')));
      return;
    }
    if (!_isValidProxyHost(host)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代理主机不是合法的 IP 或域名')));
      return;
    }

    // 开启前探测代理是否真正可达（网络可用）；不可达则不允许开启。
    setState(() => _clientProbing = true);
    final reachable = await _probeClientProxyReachable(host, port);
    if (!mounted) return;
    setState(() => _clientProbing = false);
    if (!reachable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('代理 $host:$port 无响应或不是有效的 HTTP 代理，请检查地址/端口或网络后重试'),
        ),
      );
      return;
    }

    final previous = _clientEnabled;
    setState(() => _clientEnabled = true);
    try {
      await _persistClientSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _clientEnabled = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  /// 探测上游代理是否真正可用：建立连接（加密模式先做 TLS 握手）后，发一个
  /// HTTP 代理请求（CONNECT），要求对方回有效的 HTTP 状态行（200/403/407/502…
  /// 都算"它确实是个 HTTP 代理"）。
  ///
  /// 仅 TCP 连通不够——任意监听端口（SSH、数据库、打印机、随手填的局域网 IP 上
  /// 恰好有服务）都能连上却不是代理；这里要求对方按 HTTP 代理协议应答才算通过。
  Future<bool> _probeClientProxyReachable(String host, int port) async {
    const timeout = Duration(seconds: 6);
    const probeTarget = 'example.com:443';
    final isHttpStatusLine = RegExp(r'^HTTP/1\.[01] \d{3}');
    Socket? socket;
    try {
      socket = _clientEncrypted
          ? await SecureSocket.connect(
              host,
              port,
              timeout: timeout,
              onBadCertificate: (_) => true,
            )
          : await Socket.connect(host, port, timeout: timeout);

      socket.add(
        utf8.encode(
          'CONNECT $probeTarget HTTP/1.1\r\n'
          'Host: $probeTarget\r\n'
          'Proxy-Connection: close\r\n'
          '\r\n',
        ),
      );
      await socket.flush();

      final completer = Completer<bool>();
      final buffer = StringBuffer();
      void finish(bool ok) {
        if (!completer.isCompleted) completer.complete(ok);
      }

      final timer = Timer(timeout, () => finish(false));
      final sub = socket.listen(
        (data) {
          buffer.write(latin1.decode(data));
          final text = buffer.toString();
          if (text.contains('\r\n') || text.length >= 16) {
            finish(isHttpStatusLine.hasMatch(text));
          }
        },
        onError: (_) => finish(false),
        onDone: () => finish(isHttpStatusLine.hasMatch(buffer.toString())),
        cancelOnError: true,
      );

      final ok = await completer.future;
      timer.cancel();
      await sub.cancel();
      return ok;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _onClientEncryptedChanged(bool encrypted) async {
    if (_role != NetworkProxyRole.client) return;
    final previous = _clientEncrypted;
    setState(() => _clientEncrypted = encrypted);
    try {
      await _persistClientSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _clientEncrypted = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  Future<void> _onRoleChanged(NetworkProxyRole next) async {
    _persistDebounce?.cancel();
    final previous = _role;
    setState(() => _role = next);
    try {
      if (next == NetworkProxyRole.server) {
        await _persistServerSnapshot();
      } else {
        await _persistClientSnapshot();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _role = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = NetworkProxyPresentationLabels.of(context);
    final isMobile = _isMobileLayout(context);

    final serverSegment = ButtonSegment<NetworkProxyRole>(
      value: NetworkProxyRole.server,
      label: const Text('服务端'),
      icon: const Icon(Icons.dns_rounded, size: 18),
    );
    final clientSegment = ButtonSegment<NetworkProxyRole>(
      value: NetworkProxyRole.client,
      label: const Text('客户端'),
      icon: const Icon(Icons.cloud_outlined, size: 18),
    );

    return Scaffold(
      appBar: null,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SectionLabel(icon: Icons.tune_rounded, title: '工作模式'),
                      const SizedBox(height: 6),
                      Text(
                        '服务端与客户端为二选一，不会同时启动。',
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      if (isMobile) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.settingsProxyMobileJenkinsHint,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      SegmentedButton<NetworkProxyRole>(
                        segments: isMobile
                            ? <ButtonSegment<NetworkProxyRole>>[
                                clientSegment,
                                serverSegment,
                              ]
                            : <ButtonSegment<NetworkProxyRole>>[
                                serverSegment,
                                clientSegment,
                              ],
                        selected: {_role},
                        onSelectionChanged: (s) {
                          unawaited(_onRoleChanged(s.first));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_role == NetworkProxyRole.server)
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SectionLabel(
                          icon: Icons.dns_rounded,
                          title: '内置代理',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: _serverProxyAllowHosts.isEmpty
                                    ? '代理白名单（当前允许全部）'
                                    : '代理白名单（${_serverProxyAllowHosts.length} 条）',
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                icon: Badge(
                                  isLabelVisible:
                                      _serverProxyAllowHosts.isNotEmpty,
                                  label: Text(
                                    _serverProxyAllowHosts.length.toString(),
                                  ),
                                  child: const Icon(
                                    Icons.rule_rounded,
                                    size: 20,
                                  ),
                                ),
                                onPressed: () {
                                  unawaited(_openServerProxyAllowlistDialog());
                                },
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                tooltip: l10n.proxyViewLiveRequestsButton,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                icon: const Icon(
                                  Icons.article_outlined,
                                  size: 20,
                                ),
                                onPressed: () {
                                  unawaited(_openEmbeddedProxyLiveLog(context));
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _serverEncrypted
                              ? '加密模式：客户端需使用 HTTPS 代理地址，适合内网穿透，避免明文 CONNECT 被拦截。'
                              : '明文模式：客户端使用 HTTP 代理地址，适合本机或可信局域网调试。',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('加密'),
                              icon: Icon(Icons.lock_outline_rounded, size: 18),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('明文'),
                              icon: Icon(Icons.lock_open_rounded, size: 18),
                            ),
                          ],
                          selected: {_serverEncrypted},
                          onSelectionChanged: (s) {
                            unawaited(_onServerEncryptedChanged(s.first));
                          },
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _serverEncrypted
                              ? '示例：curl --proxy-insecure -x https://host:port https://example.com'
                              : '示例：curl -x http://host:port https://example.com',
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启动监听'),
                          subtitle: Text(
                            '打开或关闭后立即写入；关闭后不占用端口。端口与仅本机/局域网在修改后约半秒自动保存。',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          value: _serverListeningEnabled,
                          onChanged: _onServerListeningToggled,
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('HTTPS 解密抓包'),
                          subtitle: Text(
                            '开启后会对 CONNECT 建立本地 MITM TLS，客户端信任根证书后可看到 HTTPS 内部 URL/path。',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          value: _serverMitmEnabled,
                          onChanged: _onServerMitmChanged,
                        ),
                        if (_serverMitmEnabled)
                          _MitmCertificateActions(
                            state: _mitmCertificateState,
                            busy: _mitmCertificateBusy,
                            installUrl: _mitmCertificatePortalUrl,
                            onOpenInstallUrl: () =>
                                unawaited(_openMitmCertificatePortal()),
                            onOpenCertificateFolder: (path) =>
                                unawaited(_openMitmCertificateFolder(path)),
                            onRefresh: () =>
                                unawaited(_refreshMitmCertificateState()),
                            onExport: () =>
                                unawaited(_exportMitmRootCertificate()),
                            onInstallMacOS: Platform.isMacOS
                                ? () => unawaited(
                                    _installMitmRootCertificateOnMacOS(),
                                  )
                                : null,
                          ),
                        if (_serverMitmEnabled && !_serverBindLoopbackOnly)
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('解密局域网设备'),
                            subtitle: Text(
                              '关闭时手机等局域网设备仍走普通 CONNECT 隧道，避免未信任证书导致无法访问。开启前请先在对应设备安装并完全信任根证书。',
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            value: _serverMitmRemoteClientsEnabled,
                            onChanged: _onServerMitmRemoteClientsChanged,
                          ),
                        const Divider(height: 24),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('仅本机'),
                              icon: Icon(Icons.home_outlined, size: 18),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('局域网'),
                              icon: Icon(Icons.router_outlined, size: 18),
                            ),
                          ],
                          selected: {_serverBindLoopbackOnly},
                          onSelectionChanged: (s) {
                            unawaited(_onServerBindChanged(s.first));
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _serverBindLoopbackOnly
                              ? '仅 127.0.0.1 可连，更安全。'
                              : '监听 0.0.0.0，同网段设备可连；请勿在不可信网络开启。',
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _serverPortCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: _portFormatters,
                          decoration: const InputDecoration(
                            labelText: '监听端口',
                            hintText: '例如 8888',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _serverUserCtrl,
                          inputFormatters: _asciiFormatters,
                          decoration: const InputDecoration(
                            labelText: '访问用户名',
                            hintText: '例如 proxy',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _serverPassCtrl,
                          obscureText: true,
                          inputFormatters: _asciiFormatters,
                          decoration: const InputDecoration(
                            labelText: '访问密码',
                            hintText: '开启监听前必须填写',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 20,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '内置代理由主窗口进程负责监听；修改后会自动保存，主窗口约 2 秒内应用。'
                                '关闭主程序后代理即停止。',
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  )
                else
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SectionLabel(
                          icon: Icons.cloud_outlined,
                          title: '上游代理',
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _clientEncrypted
                              ? '配置后，本工具访问 Jenkins 的请求会先加密连接到上游代理，再经该代理转发。'
                              : '配置后，本工具访问 Jenkins 的请求会以明文 HTTP 代理协议连接上游代理。',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('加密'),
                              icon: Icon(Icons.lock_outline_rounded, size: 18),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('明文'),
                              icon: Icon(Icons.lock_open_rounded, size: 18),
                            ),
                          ],
                          selected: {_clientEncrypted},
                          onSelectionChanged: (s) {
                            unawaited(_onClientEncryptedChanged(s.first));
                          },
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启用代理'),
                          subtitle: Text(
                            _clientProbing
                                ? '正在检测代理是否可达…'
                                : '开启前需填写主机和端口，并检测代理可达；下方主机、端口等改完后约半秒自动保存。',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          secondary: _clientProbing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          value: _clientEnabled,
                          onChanged: _clientProbing
                              ? null
                              : _onClientEnabledToggled,
                        ),
                        const Divider(height: 24),
                        TextField(
                          controller: _hostCtrl,
                          inputFormatters: _hostFormatters,
                          decoration: const InputDecoration(
                            labelText: '代理主机',
                            hintText: '例：192.168.1.10 或 proxy.corp.local',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _portCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: _portFormatters,
                          decoration: const InputDecoration(labelText: '端口'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _userCtrl,
                          inputFormatters: _asciiFormatters,
                          decoration: const InputDecoration(
                            labelText: '用户名（可选）',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passCtrl,
                          obscureText: true,
                          inputFormatters: _asciiFormatters,
                          decoration: const InputDecoration(
                            labelText: '密码（可选）',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _noProxyCtrl,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: '不走代理的主机（可选）',
                            hintText: '逗号分隔，如 localhost,127.0.0.1,.local',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 20,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '修改后会自动保存；返回主窗口并激活应用后将同步代理（已打开的 Jenkins 连接可关闭标签后重试）。',
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProxyAllowlistDialog extends StatefulWidget {
  const _ProxyAllowlistDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_ProxyAllowlistDialog> createState() => _ProxyAllowlistDialogState();
}

class _ProxyAllowlistDialogState extends State<_ProxyAllowlistDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('代理白名单'),
      content: SizedBox(
        width: 640,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '设置允许通过内置代理转发的目标主机。为空表示所有请求都允许；填写后只有匹配的主机/后缀会走本代理，其它请求会被阻止。',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: TextField(
                    controller: _controller,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      alignLabelWithHint: true,
                      labelText: '允许走代理的主机',
                      hintText:
                          '逗号或换行分隔，如：\njenkins.example.com\n.corp.local\napi.example.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '支持：精确主机 `api.example.com`，后缀 `.example.com`，或 `example.com` 匹配自身及子域。',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('清空'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<int> _revealPathInFileManager(String path) async {
  if (Platform.isMacOS) {
    final result = await Process.run('open', ['-R', path]);
    return result.exitCode;
  }
  if (Platform.isWindows) {
    final result = await Process.run('explorer.exe', ['/select,$path']);
    return result.exitCode;
  }
  if (Platform.isLinux) {
    final type = await FileSystemEntity.type(path);
    final folderPath = type == FileSystemEntityType.directory
        ? path
        : File(path).parent.path;
    final result = await Process.run('xdg-open', [folderPath]);
    return result.exitCode;
  }
  return 1;
}

Future<void> _openEmbeddedProxyLiveLog(BuildContext context) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      try {
        final existing = await _findProxyLiveLogWindow();
        if (existing != null) {
          await _showExistingProxyLiveLogWindow(existing);
          return;
        }
        final w = await WindowController.create(
          const WindowConfiguration(
            arguments: kProxyLiveLogWindowArguments,
            hiddenAtLaunch: true,
          ),
        );
        await w.show();
        return;
      } catch (e, st) {
        debugPrint('打开代理实时日志窗口失败: $e\n$st');
      }
      break;
    default:
      break;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const _EmbeddedProxyLiveLogDialog(),
  );
}

Future<WindowController?> _findProxyLiveLogWindow() async {
  final windows = await WindowController.getAll();
  for (final window in windows) {
    if (window.arguments == kProxyLiveLogWindowArguments) {
      return window;
    }
  }
  return null;
}

Future<void> _showExistingProxyLiveLogWindow(WindowController window) async {
  try {
    await window.invokeMethod<void>('showAndFocus');
  } catch (_) {
    await window.show();
  }
}

class _EmbeddedProxyLiveLogWindowPage extends StatelessWidget {
  const _EmbeddedProxyLiveLogWindowPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return _EmbeddedProxyLiveLogPanel(height: constraints.maxHeight);
            },
          ),
        ),
      ),
    );
  }
}

class _EmbeddedProxyLiveLogDialog extends ConsumerWidget {
  const _EmbeddedProxyLiveLogDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = NetworkProxyPresentationLabels.of(context);
    final screenW = MediaQuery.sizeOf(context).width;
    final logPanelW = math.min(920.0, math.max(560.0, screenW - 72));

    return AlertDialog(
      title: Text(l10n.proxyLiveLogTitle),
      content: SizedBox(
        width: logPanelW,
        child: const _EmbeddedProxyLiveLogPanel(height: 420),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.proxyLiveLogClose),
        ),
      ],
    );
  }
}

class _EmbeddedProxyLiveLogPanel extends ConsumerStatefulWidget {
  const _EmbeddedProxyLiveLogPanel({required this.height});

  final double height;

  @override
  ConsumerState<_EmbeddedProxyLiveLogPanel> createState() =>
      _EmbeddedProxyLiveLogPanelState();
}

class _EmbeddedProxyLiveLogPanelState
    extends ConsumerState<_EmbeddedProxyLiveLogPanel> {
  static const double _nameColumnWidth = 280;
  static const double _methodColumnWidth = 72;
  static const double _statusColumnWidth = 72;
  static const double _protocolColumnWidth = 110;
  static const double _hostColumnWidth = 220;
  static const double _typeColumnWidth = 96;
  static const double _sizeColumnWidth = 86;
  static const double _timeColumnWidth = 92;
  static const double _waterfallColumnWidth = 190;
  static const double _tableMinHeight = 120;
  static const double _detailsMinHeight = 120;
  static const double _splitterHeight = 8;

  final ScrollController _scrollVertical = ScrollController();
  final ScrollController _scrollHorizontal = ScrollController();
  double _detailsPaneHeight = 220;

  @override
  void dispose() {
    _scrollVertical.dispose();
    _scrollHorizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = NetworkProxyPresentationLabels.of(context);
    final theme = Theme.of(context);
    final logState = ref.watch(embeddedProxyRequestLogProvider);
    final entries = logState.filteredEntries;
    final selected = logState.selectedId == null
        ? entries.firstOrNull
        : entries.where((e) => e.id == logState.selectedId).firstOrNull;
    ref.listen(embeddedProxyRequestLogProvider, (prev, next) {
      final prevLen = prev?.entries.length ?? 0;
      if (next.entries.length > prevLen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollVertical.hasClients) return;
          _scrollVertical.jumpTo(_scrollVertical.position.maxScrollExtent);
        });
      }
    });

    return SizedBox(
      height: widget.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: logState.recording ? '停止录制' : '开始录制',
                    onPressed: () => ref
                        .read(embeddedProxyRequestLogProvider.notifier)
                        .setRecording(!logState.recording),
                    icon: Icon(
                      Icons.fiber_manual_record,
                      color: logState.recording ? Colors.redAccent : null,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.proxyLiveLogClear,
                    onPressed: () => ref
                        .read(embeddedProxyRequestLogProvider.notifier)
                        .clear(),
                    icon: const Icon(Icons.clear_all_rounded),
                  ),
                  FilterChip(
                    label: const Text('Preserve log'),
                    selected: logState.preserveLog,
                    onSelected: (v) => ref
                        .read(embeddedProxyRequestLogProvider.notifier)
                        .setPreserveLog(v),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search_rounded, size: 18),
                        hintText: 'Filter',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => ref
                          .read(embeddedProxyRequestLogProvider.notifier)
                          .setQuery(v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _ProxyTypeFilterBar(
                selected: logState.typeFilter,
                onSelected: (v) => ref
                    .read(embeddedProxyRequestLogProvider.notifier)
                    .setTypeFilter(v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                ),
              ),
              child: entries.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          l10n.proxyLiveLogEmpty,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final totalHeight = constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : widget.height;
                          final maxDetailsHeight = math.max(
                            _detailsMinHeight,
                            totalHeight - _tableMinHeight - _splitterHeight,
                          );
                          final detailsHeight = _detailsPaneHeight
                              .clamp(_detailsMinHeight, maxDetailsHeight)
                              .toDouble();
                          final tableHeight = math.max(
                            _tableMinHeight,
                            totalHeight - detailsHeight - _splitterHeight,
                          );

                          return Column(
                            children: [
                              SizedBox(
                                height: tableHeight,
                                child: Scrollbar(
                                  controller: _scrollVertical,
                                  thumbVisibility: true,
                                  child: SingleChildScrollView(
                                    controller: _scrollVertical,
                                    child: SingleChildScrollView(
                                      controller: _scrollHorizontal,
                                      scrollDirection: Axis.horizontal,
                                      child: DataTable(
                                        headingRowHeight: 34,
                                        dataRowMinHeight: 32,
                                        dataRowMaxHeight: 36,
                                        columns: const [
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Name',
                                              width: _nameColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Method',
                                              width: _methodColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Status',
                                              width: _statusColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Protocol',
                                              width: _protocolColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Host',
                                              width: _hostColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Type',
                                              width: _typeColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Size',
                                              width: _sizeColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Time',
                                              width: _timeColumnWidth,
                                            ),
                                          ),
                                          DataColumn(
                                            label: _LogHeaderCell(
                                              text: 'Waterfall',
                                              width: _waterfallColumnWidth,
                                            ),
                                          ),
                                        ],
                                        rows: [
                                          for (final e in entries)
                                            DataRow(
                                              selected: selected?.id == e.id,
                                              onSelectChanged: (_) => ref
                                                  .read(
                                                    embeddedProxyRequestLogProvider
                                                        .notifier,
                                                  )
                                                  .select(e.id),
                                              cells: [
                                                DataCell(
                                                  _LogCellText(
                                                    text: _entryName(e),
                                                    width: _nameColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text: e.method,
                                                    width: _methodColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text:
                                                        e.status?.toString() ??
                                                        '',
                                                    width: _statusColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text: e.protocol,
                                                    width: _protocolColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text: e.host,
                                                    width: _hostColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text:
                                                        proxyNetworkDevToolsType(
                                                          e,
                                                        ),
                                                    width: _typeColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text: _formatBytes(
                                                      e.bytesReceived,
                                                    ),
                                                    width: _sizeColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _LogCellText(
                                                    text: _formatDuration(
                                                      e.durationMs,
                                                    ),
                                                    width: _timeColumnWidth,
                                                  ),
                                                ),
                                                DataCell(
                                                  _WaterfallBar(entry: e),
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              _LogPaneResizer(
                                height: _splitterHeight,
                                onDragDelta: (dy) {
                                  setState(() {
                                    _detailsPaneHeight =
                                        (_detailsPaneHeight - dy)
                                            .clamp(
                                              _detailsMinHeight,
                                              maxDetailsHeight,
                                            )
                                            .toDouble();
                                  });
                                },
                              ),
                              SizedBox(
                                height: detailsHeight,
                                child: selected == null
                                    ? const Center(
                                        child: Text('Select a request'),
                                      )
                                    : _NetworkEntryDetails(entry: selected),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static String _entryName(ProxyNetworkEntry e) {
    if (e.path.isNotEmpty) return e.path;
    if (e.url.isNotEmpty) return e.url;
    return e.responseBodyPreview;
  }

  static String _formatDuration(int? ms) => ms == null ? 'Pending' : '${ms}ms';

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

class _LogHeaderCell extends StatelessWidget {
  const _LogHeaderCell({required this.text, required this.width});

  final String text;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _LogCellText extends StatelessWidget {
  const _LogCellText({required this.text, required this.width});

  final String text;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 500),
      child: SizedBox(
        width: width,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
      ),
    );
  }
}

class _LogPaneResizer extends StatelessWidget {
  const _LogPaneResizer({required this.height, required this.onDragDelta});

  final double height;
  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.outlineVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDragDelta(details.delta.dy),
        child: SizedBox(
          height: height,
          child: Center(child: Container(height: 1, color: color)),
        ),
      ),
    );
  }
}

class _WaterfallBar extends StatelessWidget {
  const _WaterfallBar({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    final duration = entry.durationMs ?? 80;
    final width = (duration / 20).clamp(20, 180).toDouble();
    final color = entry.error.isNotEmpty
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 190,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: width,
          height: 10,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

class _NetworkEntryDetails extends StatelessWidget {
  const _NetworkEntryDetails({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Headers'),
              Tab(text: 'Payload'),
              Tab(text: 'Preview'),
              Tab(text: 'Response'),
              Tab(text: 'Timing'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _HeadersDetails(entry: entry),
                _PayloadDetails(entry: entry),
                _PreviewDetails(entry: entry),
                _DetailsText(text: entry.responseBodyPreview),
                _DetailsText(
                  text: [
                    'Phase: ${entry.phase}',
                    'Started: ${DateTime.fromMillisecondsSinceEpoch(entry.startedAtMs)}',
                    'Duration: ${entry.durationMs ?? '-'} ms',
                    'Sent: ${entry.bytesSent} bytes',
                    'Received: ${entry.bytesReceived} bytes',
                    if (entry.error.isNotEmpty) 'Error: ${entry.error}',
                  ].join('\n'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadersDetails extends StatelessWidget {
  const _HeadersDetails({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Request URL', entry.url),
      ('Request Method', entry.method),
      if (entry.status != null)
        ('Status Code', '${entry.status} ${entry.statusText}'.trim()),
      ('Remote Address', entry.remoteAddress),
      (
        'Referrer Policy',
        _headerValue(entry.responseHeaders, 'referrer-policy') ??
            _headerValue(entry.requestHeaders, 'referrer-policy') ??
            '',
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderSection(title: 'General', rows: rows),
          const SizedBox(height: 12),
          _HeaderSection(
            title: 'Request Headers',
            rows: entry.requestHeaders.map((h) => (h.name, h.value)).toList(),
          ),
          const SizedBox(height: 12),
          _HeaderSection(
            title: 'Response Headers',
            rows: entry.responseHeaders.map((h) => (h.name, h.value)).toList(),
          ),
        ],
      ),
    );
  }
}

class _PayloadDetails extends StatelessWidget {
  const _PayloadDetails({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    final queryRows = _queryRows(entry.url);
    final contentType =
        _headerValue(entry.requestHeaders, 'content-type') ?? '';
    final body = entry.requestBodyPreview.trim();
    final requestPayloadRows =
        contentType.toLowerCase().contains('application/x-www-form-urlencoded')
        ? _formRows(body)
        : body.isEmpty
        ? const <(String, String)>[]
        : <(String, String)>[('Payload', body)];

    if (queryRows.isEmpty && requestPayloadRows.isEmpty) {
      return const Center(child: Text('(empty)'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (queryRows.isNotEmpty) ...[
            _HeaderSection(title: 'Query String Parameters', rows: queryRows),
            if (requestPayloadRows.isNotEmpty) const SizedBox(height: 12),
          ],
          if (requestPayloadRows.isNotEmpty)
            _HeaderSection(title: 'Request Payload', rows: requestPayloadRows),
        ],
      ),
    );
  }

  static List<(String, String)> _queryRows(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return const [];
    return [
      for (final entry in uri.queryParametersAll.entries)
        (
          Uri.decodeQueryComponent(entry.key),
          entry.value.map(Uri.decodeQueryComponent).join('\n'),
        ),
    ];
  }

  static List<(String, String)> _formRows(String body) {
    if (body.isEmpty) return const [];
    final parsed = Uri.splitQueryString(body);
    return [
      for (final entry in parsed.entries)
        (Uri.decodeQueryComponent(entry.key), entry.value),
    ];
  }
}

class _PreviewDetails extends StatelessWidget {
  const _PreviewDetails({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    final body = entry.responseBodyPreview.trim();
    if (body.isEmpty) return const Center(child: Text('(empty)'));

    final contentType =
        _headerValue(entry.responseHeaders, 'content-type')?.toLowerCase() ??
        '';
    final parsedJson = _tryParseJson(body, contentType);
    if (parsedJson != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: _JsonPreviewValue(value: parsedJson),
      );
    }

    return _PreviewUnavailable(entry: entry);
  }

  static Object? _tryParseJson(String body, String contentType) {
    final looksJson =
        contentType.contains('json') ||
        body.startsWith('{') ||
        body.startsWith('[');
    if (!looksJson) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

class _JsonPreviewValue extends StatelessWidget {
  const _JsonPreviewValue({required this.value, this.name, this.depth = 0});

  final Object? value;
  final String? name;
  final int depth;

  @override
  Widget build(BuildContext context) {
    if (value is Map) {
      final map = value as Map;
      return _JsonPreviewGroup(
        name: name,
        summary: '{${map.length}}',
        depth: depth,
        children: [
          for (final entry in map.entries)
            _JsonPreviewValue(
              name: entry.key.toString(),
              value: entry.value,
              depth: depth + 1,
            ),
        ],
      );
    }
    if (value is List) {
      final list = value as List;
      return _JsonPreviewGroup(
        name: name,
        summary: '[${list.length}]',
        depth: depth,
        children: [
          for (var i = 0; i < list.length; i++)
            _JsonPreviewValue(name: '$i', value: list[i], depth: depth + 1),
        ],
      );
    }
    return _JsonPreviewLeaf(name: name, value: value, depth: depth);
  }
}

class _JsonPreviewGroup extends StatefulWidget {
  const _JsonPreviewGroup({
    required this.summary,
    required this.children,
    this.name,
    required this.depth,
  });

  final String? name;
  final String summary;
  final int depth;
  final List<Widget> children;

  @override
  State<_JsonPreviewGroup> createState() => _JsonPreviewGroupState();
}

class _JsonPreviewGroupState extends State<_JsonPreviewGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: EdgeInsets.only(
              left: widget.depth * 14.0,
              top: 3,
              bottom: 3,
            ),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.arrow_drop_down_rounded
                      : Icons.arrow_right_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                if (widget.name != null) ...[
                  Text(
                    '${widget.name}: ',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                Text(
                  widget.summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

class _JsonPreviewLeaf extends StatelessWidget {
  const _JsonPreviewLeaf({required this.value, this.name, required this.depth});

  final String? name;
  final Object? value;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueColor = switch (value) {
      String() => scheme.primary,
      num() => scheme.tertiary,
      bool() => scheme.secondary,
      null => scheme.onSurfaceVariant,
      _ => scheme.onSurface,
    };
    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0 + 18, top: 3, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name != null)
            Text(
              '$name: ',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
              ),
            ),
          Expanded(
            child: SelectableText(
              _formatJsonLeaf(value),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: valueColor,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatJsonLeaf(Object? value) {
    if (value == null) return 'null';
    if (value is String) return jsonEncode(value);
    return value.toString();
  }
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable({required this.entry});

  final ProxyNetworkEntry entry;

  @override
  Widget build(BuildContext context) {
    final contentType =
        _headerValue(entry.responseHeaders, 'content-type') ?? '';
    final rows = <(String, String)>[
      ('Content-Type', contentType.isEmpty ? '-' : contentType),
      ('Decoded Preview Bytes', '${entry.responseBodyPreview.length}'),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderSection(title: 'Preview', rows: rows),
          const SizedBox(height: 12),
          const Text(
            'No structured preview available. Use the Response tab to inspect the raw response body.',
          ),
        ],
      ),
    );
  }
}

String? _headerValue(List<ProxyHeader> headers, String name) {
  final lower = name.toLowerCase();
  for (final header in headers) {
    if (header.name.toLowerCase() == lower) return header.value;
  }
  return null;
}

class _HeaderSection extends StatefulWidget {
  const _HeaderSection({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  State<_HeaderSection> createState() => _HeaderSectionState();
}

class _HeaderSectionState extends State<_HeaderSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(7),
                  bottom: _expanded ? Radius.zero : const Radius.circular(7),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.rows.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_expanded)
            const SizedBox.shrink()
          else if (widget.rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '(empty)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Table(
              columnWidths: const {
                0: FixedColumnWidth(170),
                1: FlexColumnWidth(),
              },
              border: TableBorder(
                horizontalInside: BorderSide(color: scheme.outlineVariant),
              ),
              children: [
                for (final row in widget.rows)
                  TableRow(
                    children: [
                      _HeaderTableCell(text: row.$1, isName: true),
                      _HeaderTableCell(text: row.$2),
                    ],
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _HeaderTableCell extends StatelessWidget {
  const _HeaderTableCell({required this.text, this.isName = false});

  final String text;
  final bool isName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: SelectableText(
        text.isEmpty ? '-' : text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: isName ? null : 'monospace',
          fontWeight: isName ? FontWeight.w600 : FontWeight.w400,
          height: 1.25,
        ),
      ),
    );
  }
}

class _DetailsText extends StatelessWidget {
  const _DetailsText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        text.isEmpty ? '(empty)' : text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.3),
      ),
    );
  }
}

class _ProxyTypeFilterBar extends StatelessWidget {
  const _ProxyTypeFilterBar({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 34,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final value in proxyNetworkTypeFilters) ...[
              _ProxyTypeChip(
                label: value,
                selected: selected == value,
                onTap: () => onSelected(value),
              ),
              const SizedBox(width: 6),
            ],
            // 末尾留一点空隙，避免最后一个 chip 贴到滚动边缘。
            SizedBox(width: 2, child: ColoredBox(color: scheme.surface)),
          ],
        ),
      ),
    );
  }
}

class _ProxyTypeChip extends StatelessWidget {
  const _ProxyTypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MitmCertificateActions extends StatelessWidget {
  const _MitmCertificateActions({
    required this.state,
    required this.busy,
    required this.installUrl,
    required this.onOpenInstallUrl,
    required this.onOpenCertificateFolder,
    required this.onRefresh,
    required this.onExport,
    required this.onInstallMacOS,
  });

  final MitmCertificateState? state;
  final bool busy;
  final String installUrl;
  final VoidCallback onOpenInstallUrl;
  final ValueChanged<String> onOpenCertificateFolder;
  final VoidCallback onRefresh;
  final VoidCallback onExport;
  final VoidCallback? onInstallMacOS;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final s = state;
    final status = s == null
        ? '正在读取证书状态…'
        : (s.exists
              ? (s.macosTrusted ? '根证书已生成并已被 macOS 信任' : '根证书已生成，客户端仍需安装并信任')
              : '尚未生成根证书，开启或导出时会自动生成');
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                s?.macosTrusted == true
                    ? Icons.verified_user_outlined
                    : Icons.security_rounded,
                size: 18,
                color: s?.macosTrusted == true
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onExport,
                icon: const Icon(Icons.file_download_outlined, size: 16),
                label: const Text('导出根证书'),
              ),
              if (onInstallMacOS != null)
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onInstallMacOS,
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('macOS 自动信任'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              IconButton(
                tooltip: '刷新证书状态',
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (s != null && s.exists) ...[
            const SizedBox(height: 4),
            Tooltip(
              message: '打开证书所在文件夹',
              child: InkWell(
                onTap: () => onOpenCertificateFolder(s.rootCertificatePath),
                borderRadius: BorderRadius.circular(4),
                mouseCursor: SystemMouseCursors.click,
                child: Text(
                  s.rootCertificatePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '证书安装页：',
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Tooltip(
              message: '打开证书安装页',
              child: InkWell(
                onTap: onOpenInstallUrl,
                borderRadius: BorderRadius.circular(4),
                mouseCursor: SystemMouseCursors.click,
                child: Text(
                  installUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '手机端请确保监听为局域网；若目标 App 只有 HTTPS 请求，请用 Safari 打开该地址安装。',
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 固定行高，确保有/无 trailing 的分区标题高度一致（trailing 的 IconButton
    // 默认 48×48 会撑高整行，导致标题与下方描述的间距不一致）。
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}
