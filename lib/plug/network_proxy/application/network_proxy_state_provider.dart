import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network_proxy.dart';

final networkProxySharedPreferencesProvider = Provider<SharedPreferences>((
  ref,
) {
  throw StateError(
    'networkProxySharedPreferencesProvider must be overridden by the host app.',
  );
});

class NetworkProxyStateController extends Notifier<NetworkProxyState> {
  @override
  NetworkProxyState build() {
    final prefs = ref.watch(networkProxySharedPreferencesProvider);
    return _read(prefs);
  }

  NetworkProxyState _read(SharedPreferences prefs) {
    return NetworkProxyStateCodec.decode(
      prefs.getString(NetworkProxyStateCodec.preferenceKey),
    );
  }

  Future<void> persist(NetworkProxyState value) async {
    final prefs = ref.read(networkProxySharedPreferencesProvider);
    await prefs.setString(
      NetworkProxyStateCodec.preferenceKey,
      NetworkProxyStateCodec.encode(value),
    );
    state = value;
  }

  /// 从磁盘重新加载（例如独立代理窗口写入后，主进程回到前台时）。
  ///
  /// 多进程/多引擎下各进程自有 `SharedPreferences` 内存缓存，必须先 [SharedPreferences.reload]
  /// 才能读到其它窗口写入的键。
  Future<void> reloadFromDisk() async {
    final prefs = ref.read(networkProxySharedPreferencesProvider);
    await prefs.reload();
    final next = _read(prefs);
    if (NetworkProxyStateCodec.encode(next) ==
        NetworkProxyStateCodec.encode(state)) {
      return;
    }
    state = next;
  }
}

final networkProxyStateProvider =
    NotifierProvider<NetworkProxyStateController, NetworkProxyState>(
      NetworkProxyStateController.new,
    );
