import 'package:deployment/core/http/jenkins_http_client.dart';
import 'package:deployment/features/settings/data/jenkins_account_qr_share.dart';
import 'package:deployment/features/settings/domain/jenkins_account.dart';
import 'package:deployment/features/settings/domain/jenkins_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy dep:j1: encode/decode roundtrip preserves config', () async {
    final account = JenkinsAccount(
      id: 'legacy-id-should-not-appear',
      name: '生产',
      config: const JenkinsConfig(
        baseUrl: 'https://jenkins.example.com/',
        username: 'alice',
        secret: 'tok/en_+=',
        authKind: JenkinsAuthKind.token,
      ),
    );
    final s = encodeJenkinsAccountShareLegacyPlain(account);
    expect(s.startsWith(jenkinsAccountSharePrefix), isTrue);
    final decoded = await decodeJenkinsAccountShare(s);
    expect(decoded, isNotNull);
    expect(decoded!.name, '生产');
    expect(decoded.config.baseUrl.trim(), 'https://jenkins.example.com/');
    expect(decoded.config.username, 'alice');
    expect(decoded.config.secret, 'tok/en_+=');
    expect(decoded.config.authKind, JenkinsAuthKind.token);
    expect(decoded.id, isNot(equals('legacy-id-should-not-appear')));
  });

  test('dep:j2: PIN-protected roundtrip', () async {
    final account = JenkinsAccount(
      id: 'x',
      name: 'staging',
      config: const JenkinsConfig(
        baseUrl: 'https://jenkins.example.org/',
        username: 'bob',
        secret: 's3cret!',
        authKind: JenkinsAuthKind.password,
      ),
    );
    const pin = '0842';
    final payload = await encodeJenkinsAccountShareProtected(account, pin);
    expect(payload.startsWith(jenkinsAccountSharePrefixV2), isTrue);
    expect(isJenkinsPinProtectedSharePayload(payload), isTrue);

    final decoded = await decodeJenkinsAccountShare(payload, pin: pin);
    expect(decoded, isNotNull);
    expect(decoded!.config.username, 'bob');
    expect(decoded.config.secret, 's3cret!');
    expect(decoded.config.authKind, JenkinsAuthKind.password);

    expect(await decodeJenkinsAccountShare(payload, pin: '0000'), isNull);
  });

  test('decode rejects garbage', () async {
    expect(await decodeJenkinsAccountShare('hello'), isNull);
    expect(
      await decodeJenkinsAccountShare('$jenkinsAccountSharePrefix@@@'),
      isNull,
    );
    expect(await decodeJenkinsAccountShare('$jenkinsAccountSharePrefixV2@@@'), isNull);
  });

  test('dep:j2: requires PIN', () async {
    final account = JenkinsAccount(
      id: 'x',
      name: 'n',
      config: const JenkinsConfig(
        baseUrl: 'https://j.example/',
        username: 'u',
        secret: 't',
        authKind: JenkinsAuthKind.token,
      ),
    );
    final payload = await encodeJenkinsAccountShareProtected(account, '1234');
    expect(await decodeJenkinsAccountShare(payload), isNull);
    expect(await decodeJenkinsAccountShare(payload, pin: '9999'), isNull);
    expect(await decodeJenkinsAccountShare(payload, pin: '1234'), isNotNull);
  });
}
