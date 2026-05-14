import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../domain/jenkins_account.dart';
import '../domain/jenkins_config.dart';

/// 旧版明文分享前缀（仍支持解码，用于兼容旧二维码）。
const jenkinsAccountSharePrefix = 'dep:j1:';

/// PIN + AES-GCM 加密分享前缀（二维码仅含密文，需 4 位数字口令解密）。
const jenkinsAccountSharePrefixV2 = 'dep:j2:';

/// PBKDF2 迭代次数（越高越难暴力猜 PIN，但扫码导入越慢）。
const jenkinsAccountShareKdfIterations = 120000;

/// Base64URL → bytes（补齐 padding）。
List<int> _base64UrlDecodeBytes(String source) {
  var output = source.replaceAll('-', '+').replaceAll('_', '/');
  switch (output.length % 4) {
    case 0:
      break;
    case 2:
      output += '==';
      break;
    case 3:
      output += '=';
      break;
    default:
      throw FormatException('invalid base64url length');
  }
  return base64Decode(output);
}

String _b64Url(List<int> bytes) => base64Url.encode(bytes);

/// 生成 4 位数字分享口令（0000–9999）。
String generateJenkinsSharePin() {
  final n = Random.secure().nextInt(10000);
  return n.toString().padLeft(4, '0');
}

bool isValidJenkinsSharePinFormat(String pin) =>
    pin.length == 4 && RegExp(r'^\d{4}$').hasMatch(pin);

bool isJenkinsPinProtectedSharePayload(String raw) =>
    raw.trim().startsWith(jenkinsAccountSharePrefixV2);

/// 是否为应用生成的账号分享载荷（扫码或粘贴均可据此预判）。
bool looksLikeJenkinsAccountSharePayload(String raw) {
  final t = raw.trim();
  return t.startsWith(jenkinsAccountSharePrefix) ||
      t.startsWith(jenkinsAccountSharePrefixV2);
}

/// dep:j1: 明文 JSON（仅测试与兼容旧数据；新分享勿使用）。
String encodeJenkinsAccountShareLegacyPlain(JenkinsAccount account) {
  final map = <String, dynamic>{
    'v': 1,
    'name': account.name,
    'baseUrl': account.config.baseUrl.trim(),
    'username': account.config.username.trim(),
    'authKind': account.config.authKind.name,
    'secret': account.config.secret,
  };
  final jsonBytes = utf8.encode(jsonEncode(map));
  final b64 = base64Url.encode(jsonBytes);
  return '$jenkinsAccountSharePrefix$b64';
}

/// 编码为 dep:j2: 密文串（供二维码）；[pinDigits] 为 4 位数字，须单独口头告知接收方。
Future<String> encodeJenkinsAccountShareProtected(
  JenkinsAccount account,
  String pinDigits,
) async {
  if (!isValidJenkinsSharePinFormat(pinDigits)) {
    throw ArgumentError.value(pinDigits, 'pinDigits', 'expected 4 digits');
  }
  final inner = <String, dynamic>{
    'v': 1,
    'name': account.name,
    'baseUrl': account.config.baseUrl.trim(),
    'username': account.config.username.trim(),
    'authKind': account.config.authKind.name,
    'secret': account.config.secret,
  };
  final plain = utf8.encode(jsonEncode(inner));
  final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final iv = List<int>.generate(12, (_) => Random.secure().nextInt(256));

  final pbkdf2 = Pbkdf2.hmacSha256(
    iterations: jenkinsAccountShareKdfIterations,
    bits: 256,
  );
  final key = await pbkdf2.deriveKeyFromPassword(
    password: pinDigits,
    nonce: salt,
  );

  final aes = AesGcm.with256bits();
  final box = await aes.encrypt(plain, secretKey: key, nonce: iv);

  final env = <String, dynamic>{
    'v': 2,
    'iters': jenkinsAccountShareKdfIterations,
    'salt': _b64Url(salt),
    'iv': _b64Url(iv),
    'ct': _b64Url(box.cipherText),
    'mac': _b64Url(box.mac.bytes),
  };
  final outer = utf8.encode(jsonEncode(env));
  return '$jenkinsAccountSharePrefixV2${_b64Url(outer)}';
}

/// 解析分享串。[pin] 仅在 dep:j2: 格式时需要。
Future<JenkinsAccount?> decodeJenkinsAccountShare(
  String raw, {
  String? pin,
}) async {
  try {
    final t = raw.trim();
    if (t.startsWith(jenkinsAccountSharePrefixV2)) {
      if (pin == null || !isValidJenkinsSharePinFormat(pin)) return null;
      return _decodeV2(t, pin);
    }
    if (t.startsWith(jenkinsAccountSharePrefix)) {
      return _decodeV1(t);
    }
    return null;
  } on Object {
    return null;
  }
}

JenkinsAccount? _decodeV1(String t) {
  try {
    final b64 = t.substring(jenkinsAccountSharePrefix.length).trim();
    if (b64.isEmpty) return null;
    final bytes = _base64UrlDecodeBytes(b64);
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map) return null;
    final v = json['v'];
    if (v != 1) return null;
    return _accountFromInnerJson(Map<String, dynamic>.from(json));
  } on Object {
    return null;
  }
}

Future<JenkinsAccount?> _decodeV2(String t, String pinDigits) async {
  final b64 = t.substring(jenkinsAccountSharePrefixV2.length).trim();
  if (b64.isEmpty) return null;
  final bytes = _base64UrlDecodeBytes(b64);
  final json = jsonDecode(utf8.decode(bytes));
  if (json is! Map) return null;
  if (json['v'] != 2) return null;
  final itersRaw = json['iters'];
  final iters = switch (itersRaw) {
    final int i => i,
    final num n => n.toInt(),
    _ => null,
  };
  if (iters == null || iters < 10000) return null;

  final saltB64 = json['salt'] as String?;
  final ivB64 = json['iv'] as String?;
  final ctB64 = json['ct'] as String?;
  final macB64 = json['mac'] as String?;
  if (saltB64 == null || ivB64 == null || ctB64 == null || macB64 == null) {
    return null;
  }
  final salt = _base64UrlDecodeBytes(saltB64);
  final iv = _base64UrlDecodeBytes(ivB64);
  final ct = _base64UrlDecodeBytes(ctB64);
  final macBytes = _base64UrlDecodeBytes(macB64);

  final pbkdf2 = Pbkdf2.hmacSha256(iterations: iters, bits: 256);
  final key = await pbkdf2.deriveKeyFromPassword(
    password: pinDigits,
    nonce: salt,
  );

  final aes = AesGcm.with256bits();
  try {
    final clear = await aes.decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(macBytes)),
      secretKey: key,
    );
    final inner = jsonDecode(utf8.decode(clear));
    if (inner is! Map || inner['v'] != 1) return null;
    return _accountFromInnerJson(Map<String, dynamic>.from(inner));
  } on SecretBoxAuthenticationError {
    return null;
  }
}

JenkinsAccount? _accountFromInnerJson(Map<String, dynamic> json) {
  final name = (json['name'] as String?) ?? '';
  final cfg = JenkinsConfig.fromPartial(
    baseUrl: json['baseUrl'] as String?,
    username: json['username'] as String?,
    secret: json['secret'] as String?,
    authKind: json['authKind'] as String?,
  );
  if (cfg == null || !cfg.isComplete) return null;
  final id = _freshImportId(cfg);
  return JenkinsAccount(id: id, name: name.trim(), config: cfg);
}

String _freshImportId(JenkinsConfig cfg) {
  final base =
      'imp_${cfg.username}@${cfg.displayHost}_${DateTime.now().millisecondsSinceEpoch}'
          .replaceAll(RegExp(r'[^A-Za-z0-9_.@-]'), '_');
  return base;
}
