import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全局安全存储句柄。
///
/// 使用系统钥匙串（macOS/iOS）、Keystore（Android）、DPAPI（Windows）。
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.unlocked_this_device),
    lOptions: LinuxOptions(),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );
});
