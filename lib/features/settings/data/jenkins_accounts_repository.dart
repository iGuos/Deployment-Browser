import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/encrypted_secret_store.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/utils/app_logger.dart';
import '../domain/jenkins_account.dart';
import '../domain/jenkins_config.dart';

const _kAccountsList = 'jenkins.accounts.list_v1';
const _kActiveAccountId = 'jenkins.accounts.active_id';

// 旧版明文回落键（flutter_secure_storage 不可用时曾用过）。仅用于一次性迁移到加密存储。
const _kSecretFallbackPrefix = 'jenkins.accounts.secret_fallback.';

// 老版（单账号）兼容 key —— 用作"首次启动迁移到默认账号"的来源。
const _kLegacyBaseUrl = 'jenkins.base_url';
const _kLegacyUsername = 'jenkins.username';
const _kLegacyAuthKind = 'jenkins.auth_kind';
const _kLegacySecretFallback = 'jenkins.secret_fallback';
const _kLegacyAccountId = 'default';

/// 多账号持久化仓储。
///
/// - 账号元数据（id / name / baseUrl / username / authKind）以 JSON 数组写入 SharedPreferences；
/// - 每个账号的 secret 用 [EncryptedSecretStore] 做**本地 AES 加密**后存入 SharedPreferences
///   （不再使用系统钥匙串 / Keystore）；
/// - 读取时若发现旧版明文回落键（`jenkins.accounts.secret_fallback.{id}`）会一次性迁移到加密存储并清除明文。
/// - 启动时若发现没有账号但存在老的单账号 key，会迁移成 id="default" 的账号。
class JenkinsAccountsRepository {
  JenkinsAccountsRepository({
    required SharedPreferences prefs,
    required EncryptedSecretStore secrets,
  })  : _prefs = prefs,
        _secrets = secrets;

  final SharedPreferences _prefs;
  final EncryptedSecretStore _secrets;

  Future<({List<JenkinsAccount> accounts, String? activeId})> read() async {
    final raw = _prefs.getString(_kAccountsList);
    if (raw == null || raw.isEmpty) {
      // 尝试从老的单账号 key 迁移
      final legacy = await _migrateLegacyAccount();
      if (legacy == null) {
        return (accounts: const <JenkinsAccount>[], activeId: null);
      }
      return (accounts: [legacy], activeId: legacy.id);
    }

    final list = <JenkinsAccount>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final entry = item.cast<String, dynamic>();
          final id = entry['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final secret = await _readSecret(id);
          if (secret == null || secret.isEmpty) continue;
          final cfg = JenkinsConfig.fromPartial(
            baseUrl: entry['baseUrl'] as String?,
            username: entry['username'] as String?,
            authKind: entry['authKind'] as String?,
            secret: secret,
          );
          if (cfg == null) continue;
          list.add(JenkinsAccount(
            id: id,
            name: (entry['name'] as String?) ?? cfg.displayHost,
            config: cfg,
          ));
        }
      }
    } catch (e) {
      appLogger.w('账号列表反序列化失败（已忽略）: $e');
    }

    final activeId = _prefs.getString(_kActiveAccountId);
    final resolvedActive = (activeId != null && list.any((a) => a.id == activeId))
        ? activeId
        : (list.isNotEmpty ? list.first.id : null);
    return (accounts: list, activeId: resolvedActive);
  }

  /// 写入整个账号集合（覆盖式）。
  Future<void> writeAll({
    required List<JenkinsAccount> accounts,
    required String? activeId,
  }) async {
    final list = accounts
        .map((a) => {
              'id': a.id,
              'name': a.name,
              'baseUrl': a.config.baseUrl,
              'username': a.config.username,
              'authKind': a.config.authKind.name,
            })
        .toList(growable: false);
    await _prefs.setString(_kAccountsList, jsonEncode(list));
    if (activeId == null || activeId.isEmpty) {
      await _prefs.remove(_kActiveAccountId);
    } else {
      await _prefs.setString(_kActiveAccountId, activeId);
    }
    // 同步 secrets：写入提供的；删除已经不在列表里的账号 secret。
    await _syncSecrets(accounts);
  }

  /// 单独保存某个账号的 secret（仅在 upsert 时使用）。
  Future<void> writeSecret(String accountId, String secret) =>
      _writeSecret(accountId, secret);

  Future<void> deleteSecret(String accountId) async {
    try {
      await _secrets.delete(accountId);
    } catch (e) {
      appLogger.w('删除加密凭证失败（已忽略）: $e');
    }
    // 顺便清除可能残留的旧版明文回落。
    await _prefs.remove('$_kSecretFallbackPrefix$accountId');
  }

  Future<void> _syncSecrets(List<JenkinsAccount> accounts) async {
    for (final a in accounts) {
      await _writeSecret(a.id, a.config.secret);
    }
    // 不在新列表中的账号的 secret 不会被同步删除，AccountsController 会在 remove
    // 流程里显式调用 deleteSecret。
  }

  Future<void> _writeSecret(String accountId, String secret) async {
    await _secrets.write(accountId, secret);
    // 写入加密存储后，清掉历史明文回落键（如果有）。
    await _prefs.remove('$_kSecretFallbackPrefix$accountId');
  }

  Future<String?> _readSecret(String accountId) async {
    final v = await _secrets.read(accountId);
    if (v != null && v.isNotEmpty) return v;
    // 迁移：旧版明文回落 → 加密存储（一次性）。
    final legacy = _prefs.getString('$_kSecretFallbackPrefix$accountId');
    if (legacy != null && legacy.isNotEmpty) {
      await _writeSecret(accountId, legacy);
      return legacy;
    }
    return null;
  }

  /// 从 v0 单账号布局里迁移一条记录到多账号布局。
  Future<JenkinsAccount?> _migrateLegacyAccount() async {
    final baseUrl = _prefs.getString(_kLegacyBaseUrl);
    final username = _prefs.getString(_kLegacyUsername);
    final authKind = _prefs.getString(_kLegacyAuthKind);
    // 旧版单账号的 secret 仅从明文键迁移（已不再使用钥匙串）。
    final secret = _prefs.getString(_kLegacySecretFallback);

    final cfg = JenkinsConfig.fromPartial(
      baseUrl: baseUrl,
      username: username,
      authKind: authKind,
      secret: secret,
    );
    if (cfg == null) return null;

    final account = JenkinsAccount(
      id: _kLegacyAccountId,
      name: cfg.displayHost,
      config: cfg,
    );
    // 写入新布局
    await writeAll(accounts: [account], activeId: account.id);
    // 老 key 留存即可（为安全起见不主动清除，避免万一回滚）。
    return account;
  }
}

final jenkinsAccountsRepositoryProvider = Provider<JenkinsAccountsRepository>((ref) {
  return JenkinsAccountsRepository(
    prefs: ref.watch(sharedPreferencesProvider),
    secrets: ref.watch(encryptedSecretStoreProvider),
  );
});

@immutable
class JenkinsAccountsState {
  const JenkinsAccountsState({
    required this.accounts,
    required this.activeId,
  });

  final List<JenkinsAccount> accounts;
  final String? activeId;

  JenkinsAccount? get activeAccount {
    final id = activeId;
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  bool get isEmpty => accounts.isEmpty;

  JenkinsAccountsState copyWith({
    List<JenkinsAccount>? accounts,
    String? activeId,
    bool clearActive = false,
  }) {
    return JenkinsAccountsState(
      accounts: accounts ?? this.accounts,
      activeId: clearActive ? null : (activeId ?? this.activeId),
    );
  }
}

/// 全应用账号集合 + 当前激活账号 id。
final jenkinsAccountsProvider =
    AsyncNotifierProvider<JenkinsAccountsController, JenkinsAccountsState>(
  JenkinsAccountsController.new,
);

class JenkinsAccountsController extends AsyncNotifier<JenkinsAccountsState> {
  @override
  Future<JenkinsAccountsState> build() async {
    final repo = ref.watch(jenkinsAccountsRepositoryProvider);
    final res = await repo.read();
    return JenkinsAccountsState(accounts: res.accounts, activeId: res.activeId);
  }

  /// 新增 / 覆盖一个账号；如果是新增且当前没有激活账号，自动设为激活。
  Future<void> upsert(JenkinsAccount account) async {
    final cur = state.value ?? const JenkinsAccountsState(accounts: [], activeId: null);
    final list = [...cur.accounts];
    final idx = list.indexWhere((a) => a.id == account.id);
    if (idx >= 0) {
      list[idx] = account;
    } else {
      list.add(account);
    }
    final activeId = cur.activeId ?? account.id;
    await ref.read(jenkinsAccountsRepositoryProvider).writeAll(
          accounts: list,
          activeId: activeId,
        );
    if (!ref.mounted) return;
    state = AsyncValue.data(JenkinsAccountsState(accounts: list, activeId: activeId));
  }

  /// 合并导入的账号：同 [JenkinsAccount.id] 覆盖已有项，否则追加；激活账号保持不变（若无则取合并后列表首项）。
  Future<void> mergeImportedAccounts(List<JenkinsAccount> imported) async {
    final cur = state.value ?? const JenkinsAccountsState(accounts: [], activeId: null);
    if (imported.isEmpty) return;
    final list = [...cur.accounts];
    for (final a in imported) {
      final idx = list.indexWhere((x) => x.id == a.id);
      if (idx >= 0) {
        list[idx] = a;
      } else {
        list.add(a);
      }
    }
    final activeId = cur.activeId ??
        (list.isNotEmpty ? list.first.id : null);
    await ref.read(jenkinsAccountsRepositoryProvider).writeAll(
          accounts: list,
          activeId: activeId,
        );
    if (!ref.mounted) return;
    state = AsyncValue.data(JenkinsAccountsState(accounts: list, activeId: activeId));
  }

  /// 删除账号；若删除的是激活账号，自动切到列表第一个（若仍有）。
  Future<void> remove(String id) async {
    final cur = state.value;
    if (cur == null) return;
    final list = [...cur.accounts]..removeWhere((a) => a.id == id);
    final activeId = cur.activeId == id
        ? (list.isNotEmpty ? list.first.id : null)
        : cur.activeId;
    await ref.read(jenkinsAccountsRepositoryProvider).writeAll(
          accounts: list,
          activeId: activeId,
        );
    if (!ref.mounted) return;
    await ref.read(jenkinsAccountsRepositoryProvider).deleteSecret(id);
    if (!ref.mounted) return;
    state = AsyncValue.data(
      JenkinsAccountsState(accounts: list, activeId: activeId),
    );
  }

  /// 调整账号在列表中的顺序（持久化顺序即全局顺序）。
  Future<void> reorderAccounts(int oldIndex, int newIndex) async {
    final cur = state.value;
    if (cur == null) return;
    final n = cur.accounts.length;
    if (n <= 1) return;
    if (oldIndex < 0 || oldIndex >= n) return;
    if (newIndex < 0 || newIndex > n) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    if (oldIndex == newIndex) return;
    final list = [...cur.accounts];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await ref.read(jenkinsAccountsRepositoryProvider).writeAll(
          accounts: list,
          activeId: cur.activeId,
        );
    if (!ref.mounted) return;
    state = AsyncValue.data(JenkinsAccountsState(accounts: list, activeId: cur.activeId));
  }

  /// 切换激活账号。
  Future<void> setActive(String id) async {
    final cur = state.value;
    if (cur == null) return;
    if (!cur.accounts.any((a) => a.id == id)) return;
    if (cur.activeId == id) return;
    await ref.read(jenkinsAccountsRepositoryProvider).writeAll(
          accounts: cur.accounts,
          activeId: id,
        );
    if (!ref.mounted) return;
    state = AsyncValue.data(cur.copyWith(activeId: id));
  }

  /// 清空所有账号（设置面板「清除」按钮调用）。
  Future<void> clearAll() async {
    final cur = state.value;
    final repo = ref.read(jenkinsAccountsRepositoryProvider);
    if (cur != null) {
      for (final a in cur.accounts) {
        await repo.deleteSecret(a.id);
        if (!ref.mounted) return;
      }
    }
    await repo.writeAll(accounts: const [], activeId: null);
    if (!ref.mounted) return;
    state = const AsyncValue.data(
      JenkinsAccountsState(accounts: [], activeId: null),
    );
  }
}
