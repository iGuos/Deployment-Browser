import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../domain/jenkins_account.dart';
import '../domain/jenkins_config.dart';

/// 明文导出（密码为空时使用）：整文件为一行 `dep:bulk:v1:` + base64url(JSON)。
const jenkinsBulkExportPrefixV1 = 'dep:bulk:v1:';

/// 密码加密导出：`dep:bulk:v2:` + base64url(JSON 信封)，解密后为与 v1 相同的内层 JSON。
const jenkinsBulkExportPrefixV2 = 'dep:bulk:v2:';

const _bulkExportKdfIterations = 120000;

/// 批量配置文件解码失败原因（供 UI 本地化）。
enum JenkinsBulkImportFailure {
  emptyPayload,
  unrecognizedFormat,
  encryptedNeedsPassword,
  wrongPasswordOrCorrupt,
  noValidAccounts,
}

/// 解析 `dep:bulk:*` 导出文件失败时抛出。
class JenkinsBulkImportDecodeException implements Exception {
  JenkinsBulkImportDecodeException(this.failure);

  final JenkinsBulkImportFailure failure;

  @override
  String toString() => 'JenkinsBulkImportDecodeException($failure)';
}

String _b64Url(List<int> bytes) => base64Url.encode(bytes);

List<int> _b64UrlDecode(String s) => base64Url.decode(s);

Map<String, dynamic> _payloadMap(List<JenkinsAccount> accounts) => {
      'v': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'accounts': accounts
          .map(
            (a) => {
              'id': a.id,
              'name': a.name,
              'baseUrl': a.config.baseUrl.trim(),
              'username': a.config.username.trim(),
              'authKind': a.config.authKind.name,
              'secret': a.config.secret,
            },
          )
          .toList(),
    };

/// 导出账号列表为单行文本。
///
/// [password] 为空时使用 [jenkinsBulkExportPrefixV1]（仅 base64，**含明文密钥**，须自行保管文件）。
/// 非空时使用 PBKDF2 + AES-GCM 加密（[jenkinsBulkExportPrefixV2]）。
Future<String> encodeJenkinsAccountsExport(
  List<JenkinsAccount> accounts,
  String password,
) async {
  final inner = _payloadMap(accounts);
  final plain = utf8.encode(jsonEncode(inner));
  final pwd = password.trim();
  if (pwd.isEmpty) {
    return '$jenkinsBulkExportPrefixV1${_b64Url(plain)}';
  }

  final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final iv = List<int>.generate(12, (_) => Random.secure().nextInt(256));

  final pbkdf2 = Pbkdf2.hmacSha256(
    iterations: _bulkExportKdfIterations,
    bits: 256,
  );
  final key = await pbkdf2.deriveKeyFromPassword(
    password: pwd,
    nonce: salt,
  );

  final aes = AesGcm.with256bits();
  final box = await aes.encrypt(plain, secretKey: key, nonce: iv);

  final env = <String, dynamic>{
    'v': 2,
    'iters': _bulkExportKdfIterations,
    'salt': _b64Url(salt),
    'iv': _b64Url(iv),
    'ct': _b64Url(box.cipherText),
    'mac': _b64Url(box.mac.bytes),
  };
  final outer = utf8.encode(jsonEncode(env));
  return '$jenkinsBulkExportPrefixV2${_b64Url(outer)}';
}

List<JenkinsAccount> _accountsFromBulkInnerJson(Map<String, dynamic> inner) {
  final accounts = inner['accounts'];
  if (accounts is! List) {
    throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.noValidAccounts);
  }
  final out = <JenkinsAccount>[];
  for (final item in accounts) {
    if (item is! Map) continue;
    final m = Map<String, dynamic>.from(item);
    final id = (m['id'] as String?)?.trim();
    final nameRaw = (m['name'] as String?)?.trim();
    final cfg = JenkinsConfig.fromPartial(
      baseUrl: m['baseUrl'] as String?,
      username: m['username'] as String?,
      secret: m['secret'] as String?,
      authKind: m['authKind'] as String?,
    );
    if (id == null || id.isEmpty || cfg == null || !cfg.isComplete) continue;
    final name = (nameRaw != null && nameRaw.isNotEmpty) ? nameRaw : cfg.displayHost;
    out.add(JenkinsAccount(id: id, name: name, config: cfg));
  }
  if (out.isEmpty) {
    throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.noValidAccounts);
  }
  return out;
}

/// 将导出文件正文解析为账号列表。
///
/// [password]：仅 [jenkinsBulkExportPrefixV2] 需要，须与导出时一致；明文 [jenkinsBulkExportPrefixV1] 忽略密码。
Future<List<JenkinsAccount>> decodeJenkinsAccountsExport(
  String text,
  String password,
) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.emptyPayload);
  }

  if (trimmed.startsWith(jenkinsBulkExportPrefixV1)) {
    final b64 = trimmed.substring(jenkinsBulkExportPrefixV1.length).trim();
    if (b64.isEmpty) {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }
    try {
      final plain = utf8.decode(_b64UrlDecode(b64));
      final json = jsonDecode(plain);
      if (json is! Map) {
        throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
      }
      return _accountsFromBulkInnerJson(Map<String, dynamic>.from(json));
    } on FormatException {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    } on JenkinsBulkImportDecodeException {
      rethrow;
    }
  }

  if (trimmed.startsWith(jenkinsBulkExportPrefixV2)) {
    final pwd = password.trim();
    if (pwd.isEmpty) {
      throw JenkinsBulkImportDecodeException(
        JenkinsBulkImportFailure.encryptedNeedsPassword,
      );
    }
    final b64 = trimmed.substring(jenkinsBulkExportPrefixV2.length).trim();
    if (b64.isEmpty) {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }
    Map<String, dynamic> env;
    try {
      final raw = jsonDecode(utf8.decode(_b64UrlDecode(b64)));
      if (raw is! Map) {
        throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
      }
      env = Map<String, dynamic>.from(raw);
    } on JenkinsBulkImportDecodeException {
      rethrow;
    } on Object {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }
    if (env['v'] != 2) {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }
    final itersRaw = env['iters'];
    final iters = switch (itersRaw) {
      final int i => i,
      final num n => n.toInt(),
      _ => null,
    };
    if (iters == null || iters < 10000) {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }

    final saltB64 = env['salt'] as String?;
    final ivB64 = env['iv'] as String?;
    final ctB64 = env['ct'] as String?;
    final macB64 = env['mac'] as String?;
    if (saltB64 == null || ivB64 == null || ctB64 == null || macB64 == null) {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
    }
    final salt = _b64UrlDecode(saltB64);
    final iv = _b64UrlDecode(ivB64);
    final ct = _b64UrlDecode(ctB64);
    final macBytes = _b64UrlDecode(macB64);

    final pbkdf2 = Pbkdf2.hmacSha256(iterations: iters, bits: 256);
    final key = await pbkdf2.deriveKeyFromPassword(
      password: pwd,
      nonce: salt,
    );

    final aes = AesGcm.with256bits();
    try {
      final clear = await aes.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(macBytes)),
        secretKey: key,
      );
      final inner = jsonDecode(utf8.decode(clear));
      if (inner is! Map) {
        throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.wrongPasswordOrCorrupt);
      }
      return _accountsFromBulkInnerJson(Map<String, dynamic>.from(inner));
    } on SecretBoxAuthenticationError {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.wrongPasswordOrCorrupt);
    } on FormatException {
      throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.wrongPasswordOrCorrupt);
    } on JenkinsBulkImportDecodeException {
      rethrow;
    }
  }

  throw JenkinsBulkImportDecodeException(JenkinsBulkImportFailure.unrecognizedFormat);
}
