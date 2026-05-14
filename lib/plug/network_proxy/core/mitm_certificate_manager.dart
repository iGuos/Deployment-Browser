import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

class MitmCertificateState {
  const MitmCertificateState({
    required this.rootCertificatePath,
    required this.rootKeyPath,
    required this.exists,
    required this.macosTrusted,
    this.error,
  });

  final String rootCertificatePath;
  final String rootKeyPath;
  final bool exists;
  final bool macosTrusted;
  final String? error;
}

class MitmHostCertificate {
  const MitmHostCertificate({
    required this.certificatePath,
    required this.privateKeyPath,
  });

  final String certificatePath;
  final String privateKeyPath;
}

class MitmCertificateManager {
  MitmCertificateManager({Directory? baseDirectory})
    : _baseDirectory = baseDirectory ?? Directory(_defaultBasePath());

  static const _rootSubject = {
    'CN': 'Deployment MITM Proxy Root CA',
    'O': 'Deployment',
  };

  final Directory _baseDirectory;
  final Map<String, Future<MitmHostCertificate>> _hostCertificateTasks = {};
  Future<File>? _rootCertificateTask;

  File get rootCertificateFile => File('${_baseDirectory.path}/root_ca.pem');
  File get rootKeyFile => File('${_baseDirectory.path}/root_ca.key');
  File get rootCertificateDerFile => File('${_baseDirectory.path}/root_ca.cer');
  Directory get _hostDirectory => Directory('${_baseDirectory.path}/hosts');

  Future<MitmCertificateState> inspect() async {
    String? error;
    final exists =
        await rootCertificateFile.exists() && await rootKeyFile.exists();
    var trusted = false;
    if (Platform.isMacOS && exists) {
      try {
        trusted = await isRootCertificateTrustedOnMacOS();
      } catch (e) {
        error = e.toString();
      }
    }
    return MitmCertificateState(
      rootCertificatePath: rootCertificateFile.path,
      rootKeyPath: rootKeyFile.path,
      exists: exists,
      macosTrusted: trusted,
      error: error,
    );
  }

  Future<File> ensureRootCertificate() async {
    final running = _rootCertificateTask;
    if (running != null) return running;
    final task = _ensureRootCertificate();
    _rootCertificateTask = task;
    try {
      return await task;
    } finally {
      _rootCertificateTask = null;
    }
  }

  Future<File> _ensureRootCertificate() async {
    await _baseDirectory.create(recursive: true);
    if (await rootCertificateFile.exists() && await rootKeyFile.exists()) {
      return rootCertificateFile;
    }

    final keyPair = CryptoUtils.generateRSAKeyPair();
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem(
      _rootSubject,
      privateKey,
      publicKey,
    );
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      keyUsage: const [KeyUsage.KEY_CERT_SIGN, KeyUsage.CRL_SIGN],
      cA: true,
      serialNumber: _serialNumber(),
      issuer: _rootSubject,
      notBefore: _notBefore(),
    );
    await rootKeyFile.writeAsString(
      CryptoUtils.encodeRSAPrivateKeyToPem(privateKey),
      encoding: utf8,
    );
    await rootCertificateFile.writeAsString(certificate, encoding: utf8);
    return rootCertificateFile;
  }

  Future<MitmHostCertificate> ensureHostCertificate(String host) async {
    final normalized = _normalizeHost(host);
    final running = _hostCertificateTasks[normalized];
    if (running != null) return running;
    final task = _ensureHostCertificate(normalized);
    _hostCertificateTasks[normalized] = task;
    try {
      return await task;
    } finally {
      _hostCertificateTasks.remove(normalized);
    }
  }

  Future<MitmHostCertificate> _ensureHostCertificate(String normalized) async {
    await ensureRootCertificate();
    await _hostDirectory.create(recursive: true);

    final safe = _safeFileName(normalized);
    final cert = File('${_hostDirectory.path}/$safe.pem');
    final key = File('${_hostDirectory.path}/$safe.key');

    if (await cert.exists() &&
        await key.exists() &&
        await _isHostCertificateCurrent(cert, safe)) {
      return MitmHostCertificate(
        certificatePath: cert.path,
        privateKeyPath: key.path,
      );
    }
    await _deleteIfExists(cert);
    await _deleteIfExists(key);

    await _generateHostCertificateWithOpenSsl(
      normalized: normalized,
      safe: safe,
      cert: cert,
      key: key,
    );

    return MitmHostCertificate(
      certificatePath: cert.path,
      privateKeyPath: key.path,
    );
  }

  Future<void> _generateHostCertificateWithOpenSsl({
    required String normalized,
    required String safe,
    required File cert,
    required File key,
  }) async {
    final csr = File('${_hostDirectory.path}/$safe.csr');
    final ext = File('${_hostDirectory.path}/$safe.ext');
    final serial = File('${_baseDirectory.path}/root_ca.srl');
    await ext.writeAsString(
      [
        'basicConstraints=critical,CA:FALSE',
        'keyUsage=digitalSignature,keyEncipherment',
        'extendedKeyUsage=serverAuth',
        'subjectAltName=${_subjectAlternativeName(normalized)}',
        '',
      ].join('\n'),
      encoding: utf8,
    );
    await _runProcess('openssl', ['genrsa', '-out', key.path, '2048']);
    await _runProcess('openssl', [
      'req',
      '-new',
      '-key',
      key.path,
      '-out',
      csr.path,
      '-subj',
      '/CN=${_escapeOpenSslSubject(normalized)}/O=Deployment',
    ]);
    await _runProcess('openssl', [
      'x509',
      '-req',
      '-in',
      csr.path,
      '-CA',
      rootCertificateFile.path,
      '-CAkey',
      rootKeyFile.path,
      if (await serial.exists()) '-CAserial' else '-CAcreateserial',
      if (await serial.exists()) serial.path,
      '-out',
      cert.path,
      '-days',
      '825',
      '-sha256',
      '-extfile',
      ext.path,
    ]);
  }

  Future<String> rootCertificatePem() async {
    await ensureRootCertificate();
    return rootCertificateFile.readAsString(encoding: utf8);
  }

  Future<List<int>> rootCertificateDerBytes() async {
    final pem = await rootCertificatePem();
    final bytes = CryptoUtils.getBytesFromPEMString(pem);
    await rootCertificateDerFile.writeAsBytes(bytes);
    return bytes;
  }

  Future<String> rootCertificateSha256Fingerprint() async {
    final bytes = await rootCertificateDerBytes();
    final digest = sha256.convert(Uint8List.fromList(bytes));
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  Future<bool> _isHostCertificateCurrent(File cert, String safe) async {
    try {
      final ext = File('${_hostDirectory.path}/$safe.ext');
      if (!await ext.exists()) return false;
      final rootStat = await rootCertificateFile.stat();
      final certStat = await cert.stat();
      return !certStat.modified.isBefore(rootStat.modified);
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _runProcess(String executable, List<String> args) async {
    final res = await Process.run(executable, args);
    if (res.exitCode == 0) return;
    throw ProcessException(
      executable,
      args,
      '${res.stderr}\n${res.stdout}'.trim(),
      res.exitCode,
    );
  }

  Future<void> installRootCertificateOnMacOS() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('仅 macOS 支持自动安装到钥匙串');
    }
    await ensureRootCertificate();
    await _runProcessWithMacOSAuthFocus('security', [
      'add-trusted-cert',
      '-d',
      '-r',
      'trustRoot',
      '-k',
      '${Platform.environment['HOME']}/Library/Keychains/login.keychain-db',
      rootCertificateFile.path,
    ]);
  }

  Future<bool> isRootCertificateTrustedOnMacOS() async {
    if (!Platform.isMacOS) return false;
    if (!await rootCertificateFile.exists()) return false;
    final res = await Process.run('security', [
      'verify-cert',
      '-c',
      rootCertificateFile.path,
    ]);
    return res.exitCode == 0;
  }

  SecurityContext securityContextForHost(MitmHostCertificate cert) {
    final context = SecurityContext();
    context.useCertificateChain(cert.certificatePath);
    context.usePrivateKey(cert.privateKeyPath);
    return context;
  }

  Future<void> _runProcessWithMacOSAuthFocus(
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(executable, args);
    final focusTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      _focusMacOSAuthorizationPrompt();
    });
    try {
      final stderr = StringBuffer();
      final stdout = StringBuffer();
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .listen(stderr.write);
      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .listen(stdout.write);
      final exitCode = await process.exitCode;
      await stderrSub.cancel();
      await stdoutSub.cancel();
      if (exitCode == 0) return;
      throw ProcessException(
        executable,
        args,
        '${stderr.toString()}\n${stdout.toString()}'.trim(),
        exitCode,
      );
    } finally {
      focusTimer.cancel();
    }
  }

  void _focusMacOSAuthorizationPrompt() {
    if (!Platform.isMacOS) return;
    unawaited(
      Process.run('osascript', [
        '-e',
        '''
tell application "System Events"
  repeat with processName in {"SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter"}
    if exists process processName then
      set frontmost of process processName to true
      return
    end if
  end repeat
end tell
''',
      ]).catchError((_) => ProcessResult(0, 1, '', '')),
    );
  }

  static String _normalizeHost(String host) {
    var normalized = host.trim();
    if (normalized.startsWith('[') && normalized.endsWith(']')) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    return normalized;
  }

  static String _safeFileName(String host) {
    return host.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  }

  static String _subjectAlternativeName(String host) {
    final address = InternetAddress.tryParse(host);
    if (address != null) return 'IP:$host';
    return 'DNS:$host';
  }

  static String _escapeOpenSslSubject(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('/', r'\/');
  }

  static DateTime _notBefore() {
    return DateTime.now().toUtc().subtract(const Duration(days: 1));
  }

  static String _serialNumber() {
    final random = Random.secure().nextInt(0x7fffffff);
    final value =
        BigInt.from(DateTime.now().microsecondsSinceEpoch) *
            BigInt.from(0x80000000) +
        BigInt.from(random);
    return value.toString();
  }

  static String _defaultBasePath() {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      if (Platform.isMacOS) {
        return '$home/Library/Application Support/Deployment/mitm';
      }
      return '$home/.deployment/mitm';
    }
    return '${Directory.systemTemp.path}/deployment_mitm';
  }
}
