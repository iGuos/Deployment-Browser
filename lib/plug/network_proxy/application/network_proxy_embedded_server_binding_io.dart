import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/http_forward_proxy_server.dart';
import '../core/network_proxy_state.dart';
import '../core/network_proxy_state_codec.dart';
import '../core/proxy_role.dart';
import 'embedded_proxy_log_cross_window_io.dart';
import 'embedded_proxy_request_log_provider.dart';
import 'network_proxy_logger.dart';
import 'network_proxy_state_provider.dart';

/// 根据 [networkProxyStateProvider] 启动 / 停止内置转发代理。
void registerNetworkProxyEmbeddedServer(Ref ref) {
  final logger = ref.read(networkProxyLoggerProvider);
  final server = HttpForwardProxyServer(
    onLog: (m) {
      logger(m);
      ref.read(embeddedProxyRequestLogProvider.notifier).addLine(m);
      tryBroadcastEmbeddedProxyLogLine(m);
    },
    onNetworkEvent: (event) {
      ref.read(embeddedProxyRequestLogProvider.notifier).applyEvent(event);
      tryBroadcastEmbeddedProxyNetworkEvent(event);
    },
  );

  /// 串行执行 close/bind，避免 [ref.listen] 连续触发时并发竞态。
  Future<void> syncTail = Future.value();
  void enqueueSync(NetworkProxyState s) {
    syncTail = syncTail.then((_) => _syncEmbeddedProxy(server, s, logger));
  }

  // 启动时先刷新一次磁盘配置，确保上次退出前保存的监听开关会立即恢复。
  unawaited(ref.read(networkProxyStateProvider.notifier).reloadFromDisk());

  /// 独立代理窗口（另一引擎/进程）写入 prefs 后，主进程内存缓存不会自动更新，需 [SharedPreferences.reload] 再比对。
  final poll = Timer.periodic(const Duration(seconds: 2), (_) {
    unawaited(() async {
      final prefs = ref.read(networkProxySharedPreferencesProvider);
      try {
        await prefs.reload();
      } catch (e, st) {
        logger(
          'SharedPreferences.reload 失败（代理状态轮询跳过）',
          error: e,
          stackTrace: st,
        );
        return;
      }
      final raw = prefs.getString(NetworkProxyStateCodec.preferenceKey);
      final diskEnc = NetworkProxyStateCodec.encode(
        NetworkProxyStateCodec.decode(raw),
      );
      final memEnc = NetworkProxyStateCodec.encode(
        ref.read(networkProxyStateProvider),
      );
      if (diskEnc != memEnc) {
        await ref.read(networkProxyStateProvider.notifier).reloadFromDisk();
      }
    }());
  });

  ref.listen<NetworkProxyState>(networkProxyStateProvider, (prev, next) {
    enqueueSync(next);
  }, fireImmediately: true);
  ref.onDispose(() {
    poll.cancel();
    unawaited(syncTail.then((_) => server.close()));
  });
}

Future<void> _syncEmbeddedProxy(
  HttpForwardProxyServer server,
  NetworkProxyState s,
  NetworkProxyLogger logger,
) async {
  final wasListening = server.isListening;
  await server.close();
  if (!s.shouldRunEmbeddedProxyServer) {
    if (wasListening) {
      logger('内置代理：监听已关闭。（${_embeddedProxySkipReason(s)}）');
    } else {
      logger('内置代理：当前未监听 — ${_embeddedProxySkipReason(s)}');
    }
    return;
  }
  final addr = s.server.listenOnLoopbackOnly
      ? InternetAddress.loopbackIPv4
      : InternetAddress.anyIPv4;
  final port = s.server.port;
  final modeLabel = s.server.encrypted ? 'TLS 加密' : '明文';
  logger(
    '内置代理：正在启动 $modeLabel 监听 ${addr.address}:$port（loopbackOnly=${s.server.listenOnLoopbackOnly}）…',
  );
  try {
    await server.bind(
      address: addr,
      port: port,
      encrypted: s.server.encrypted,
      mitmEnabled: s.server.mitmEnabled,
      mitmRemoteClientsEnabled: s.server.mitmRemoteClientsEnabled,
      proxyAllowHosts: s.server.proxyAllowHosts,
      authUsername: s.server.username,
      authPassword: s.server.password,
    );
    logger('内置代理：$modeLabel 监听已开启 ${addr.address}:$port');
  } catch (e, st) {
    logger('内置代理：绑定失败（端口 $port）', error: e, stackTrace: st);
  }
}

String _embeddedProxySkipReason(NetworkProxyState s) {
  if (s.role != NetworkProxyRole.server) {
    return '工作模式为 ${s.role.name}（需选「服务端」）';
  }
  if (!s.server.listeningEnabled) {
    return '「启动监听」为关';
  }
  if (!s.server.isListenConfigured) {
    return '端口无效或未填（当前 port=${s.server.port}）';
  }
  if (!s.server.hasAuth) {
    return '未填写访问用户名或密码';
  }
  return '条件不满足';
}
