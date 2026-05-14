import 'package:deployment/core/http/jenkins_http_client.dart';
import 'package:deployment/features/settings/data/jenkins_accounts_bulk_export.dart';
import 'package:deployment/features/settings/domain/jenkins_account.dart';
import 'package:deployment/features/settings/domain/jenkins_config.dart';
import 'package:flutter_test/flutter_test.dart';

JenkinsAccount _sample(String id) {
  return JenkinsAccount(
    id: id,
    name: 'Test',
    config: const JenkinsConfig(
      baseUrl: 'https://jenkins.example.com/',
      username: 'u1',
      secret: 'secret-token',
      authKind: JenkinsAuthKind.token,
    ),
  );
}

void main() {
  test('bulk v1 roundtrip', () async {
    final accounts = [_sample('a1'), _sample('a2')];
    final line = await encodeJenkinsAccountsExport(accounts, '');
    expect(line.startsWith(jenkinsBulkExportPrefixV1), isTrue);

    final decoded = await decodeJenkinsAccountsExport(line, '');
    expect(decoded.length, 2);
    expect(decoded.map((a) => a.id).toList(), ['a1', 'a2']);
    expect(decoded.first.config.username, 'u1');
  });

  test('bulk v2 roundtrip', () async {
    final accounts = [_sample('id-v2')];
    final line = await encodeJenkinsAccountsExport(accounts, 'my-pass');
    expect(line.startsWith(jenkinsBulkExportPrefixV2), isTrue);

    final decoded = await decodeJenkinsAccountsExport(line, 'my-pass');
    expect(decoded.single.id, 'id-v2');
    expect(decoded.single.config.secret, 'secret-token');
  });

  test('bulk v2 rejects empty password', () async {
    final line = await encodeJenkinsAccountsExport([_sample('x')], 'p');
    expect(
      () => decodeJenkinsAccountsExport(line, ''),
      throwsA(isA<JenkinsBulkImportDecodeException>().having(
        (e) => e.failure,
        'failure',
        JenkinsBulkImportFailure.encryptedNeedsPassword,
      )),
    );
  });

  test('bulk v2 wrong password', () async {
    final line = await encodeJenkinsAccountsExport([_sample('x')], 'right');
    expect(
      () => decodeJenkinsAccountsExport(line, 'wrong'),
      throwsA(isA<JenkinsBulkImportDecodeException>().having(
        (e) => e.failure,
        'failure',
        JenkinsBulkImportFailure.wrongPasswordOrCorrupt,
      )),
    );
  });

  test('bulk unrecognized payload', () async {
    expect(
      () => decodeJenkinsAccountsExport('not-a-bulk-file', ''),
      throwsA(isA<JenkinsBulkImportDecodeException>().having(
        (e) => e.failure,
        'failure',
        JenkinsBulkImportFailure.unrecognizedFormat,
      )),
    );
  });
}
