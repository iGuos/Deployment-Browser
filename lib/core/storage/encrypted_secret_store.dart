import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preferences.dart';

/// 本地自加密的凭证存储（不使用系统钥匙串 / Keystore）。
///
/// - 用 AES-GCM-256 加密每条密钥，密文(iv+ct+mac)以 JSON 信封存入 SharedPreferences；
/// - 加密主密钥首次运行随机生成（32 字节），base64 持久化在本地。
///
/// 安全级别说明：主密钥与密文同在本机，属于**本地混淆/加密**——可防止配置文件
/// 被明文直接读取，但无法抵御能完整访问本机文件的攻击者。需要更强保护时应改为
/// 由用户主密码派生密钥（PBKDF2），或重新引入平台安全存储。
class EncryptedSecretStore {
  EncryptedSecretStore(this._prefs);

  final SharedPreferences _prefs;

  /// 主密钥（base64）持久化键。
  static const masterKeyPrefKey = 'app.local_secret_key_v1';

  /// 每条密文条目的键前缀：`app.sec_enc.<logicalKey>`。
  static const entryPrefix = 'app.sec_enc.';

  final AesGcm _aes = AesGcm.with256bits();
  SecretKey? _cachedKey;

  Future<SecretKey> _masterKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final stored = _prefs.getString(masterKeyPrefKey);
    if (stored != null && stored.isNotEmpty) {
      final key = SecretKey(base64Decode(stored));
      _cachedKey = key;
      return key;
    }
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _prefs.setString(masterKeyPrefKey, base64Encode(bytes));
    final key = SecretKey(bytes);
    _cachedKey = key;
    return key;
  }

  String _entryKey(String logicalKey) => '$entryPrefix$logicalKey';

  /// 读取并解密；不存在或解密失败返回 null。
  Future<String?> read(String logicalKey) async {
    final raw = _prefs.getString(_entryKey(logicalKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      final env = jsonDecode(raw) as Map<String, dynamic>;
      final iv = base64Decode(env['iv'] as String);
      final ct = base64Decode(env['ct'] as String);
      final mac = base64Decode(env['mac'] as String);
      final clear = await _aes.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(mac)),
        secretKey: await _masterKey(),
      );
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  /// 加密并写入。
  Future<void> write(String logicalKey, String value) async {
    final iv = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await _aes.encrypt(
      utf8.encode(value),
      secretKey: await _masterKey(),
      nonce: iv,
    );
    final env = jsonEncode({
      'iv': base64Encode(iv),
      'ct': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
    await _prefs.setString(_entryKey(logicalKey), env);
  }

  Future<void> delete(String logicalKey) async {
    await _prefs.remove(_entryKey(logicalKey));
  }
}

/// 全局本地加密凭证存储。
final encryptedSecretStoreProvider = Provider<EncryptedSecretStore>((ref) {
  return EncryptedSecretStore(ref.watch(sharedPreferencesProvider));
});
