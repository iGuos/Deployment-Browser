import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:deployment/plug/network_proxy/core/mitm_certificate_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates root and host certificates', () async {
    final dir = await Directory.systemTemp.createTemp('deployment_mitm_test_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final manager = MitmCertificateManager(baseDirectory: dir);
    final root = await manager.ensureRootCertificate();
    final host = await manager.ensureHostCertificate('example.com');
    final derBytes = await manager.rootCertificateDerBytes();
    final state = await manager.inspect();
    final rootPem = await root.readAsString();
    final hostPem = await File(host.certificatePath).readAsString();

    expect(await root.exists(), isTrue);
    expect(await File(host.certificatePath).exists(), isTrue);
    expect(await File(host.privateKeyPath).exists(), isTrue);
    expect(derBytes, isNotEmpty);
    expect(state.exists, isTrue);
    expect(X509Utils.checkX509Signature(rootPem), isTrue);
    expect(X509Utils.checkX509Signature(hostPem, parent: rootPem), isTrue);
    expect(() => manager.securityContextForHost(host), returnsNormally);
  });
}
