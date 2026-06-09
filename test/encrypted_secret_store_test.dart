import 'package:deployment/core/storage/encrypted_secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptedSecretStore', () {
    late SharedPreferences prefs;
    late EncryptedSecretStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = EncryptedSecretStore(prefs);
    });

    test('write/read roundtrip', () async {
      await store.write('acct-1', 'super-secret-token');
      expect(await store.read('acct-1'), 'super-secret-token');
    });

    test('stored value is encrypted, not plaintext', () async {
      const secret = 'p5IM4I95-Fq9F1u';
      await store.write('acct-1', secret);
      final raw = prefs.getString('${EncryptedSecretStore.entryPrefix}acct-1');
      expect(raw, isNotNull);
      // 明文不应出现在持久化内容里。
      expect(raw!.contains(secret), isFalse);
      // 主密钥已生成。
      expect(prefs.getString(EncryptedSecretStore.masterKeyPrefKey), isNotNull);
    });

    test('read missing key returns null', () async {
      expect(await store.read('nope'), isNull);
    });

    test('delete removes the entry', () async {
      await store.write('acct-1', 'x');
      await store.delete('acct-1');
      expect(await store.read('acct-1'), isNull);
    });

    test('survives a fresh store instance (key persisted)', () async {
      await store.write('acct-1', 'persisted-secret');
      final store2 = EncryptedSecretStore(prefs);
      expect(await store2.read('acct-1'), 'persisted-secret');
    });

    test('decrypt fails gracefully if master key changes', () async {
      await store.write('acct-1', 'secret');
      // 模拟主密钥丢失/被替换：旧密文无法解出，返回 null 而非抛异常。
      await prefs.remove(EncryptedSecretStore.masterKeyPrefKey);
      final store2 = EncryptedSecretStore(prefs);
      expect(await store2.read('acct-1'), isNull);
    });
  });
}
