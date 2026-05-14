import 'package:deployment/features/jenkins/domain/build_parameter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuildParameter.mergeForTrigger', () {
    test('fills defaults when overrides empty', () {
      final defs = [
        const BuildParameter(
          name: 'SERVICE',
          kind: BuildParameterKind.string,
          defaultValue: 'api',
        ),
      ];
      final m = BuildParameter.mergeForTrigger(defs, {});
      expect(m, {'SERVICE': 'api'});
    });

    test('uses UI override when present', () {
      final defs = [
        const BuildParameter(
          name: 'SERVICE',
          kind: BuildParameterKind.string,
          defaultValue: 'api',
        ),
      ];
      final m = BuildParameter.mergeForTrigger(defs, {'SERVICE': 'web'});
      expect(m, {'SERVICE': 'web'});
    });

    test('choice with empty API default uses first choice', () {
      final defs = [
        const BuildParameter(
          name: 'ENV',
          kind: BuildParameterKind.choice,
          defaultValue: '',
          choices: ['staging', 'prod'],
        ),
      ];
      final m = BuildParameter.mergeForTrigger(defs, {});
      expect(m, {'ENV': 'staging'});
    });
  });

  group('BuildParameter.isLikelyBranch', () {
    test('git parameter plugin class', () {
      final p = BuildParameter.fromJson({
        '_class': 'net.uaznia.lukanus.hudson.plugins.gitparameter.GitParameterDefinition',
        'name': 'BRANCH',
      });
      expect(p.kind, BuildParameterKind.gitBranch);
      expect(p.isLikelyBranch, isTrue);
    });

    test('plain string with branch-like name is detected', () {
      const p = BuildParameter(
        name: 'BRANCH',
        kind: BuildParameterKind.string,
        defaultValue: 'main',
      );
      expect(p.isLikelyBranch, isTrue);
    });

    test('boolean named "branchEnabled" is NOT branch', () {
      const p = BuildParameter(
        name: 'branchEnabled',
        kind: BuildParameterKind.boolean,
        defaultValue: 'false',
      );
      expect(p.isLikelyBranch, isFalse);
    });

    test('arbitrary string param is not branch', () {
      const p = BuildParameter(
        name: 'SERVICE',
        kind: BuildParameterKind.string,
        defaultValue: '',
      );
      expect(p.isLikelyBranch, isFalse);
    });
  });

  group('BuildParameter.pickPrimaryBranch', () {
    test('non-empty defaultValue wins', () {
      final picked = BuildParameter.pickPrimaryBranch(
        'release/2026',
        ['main', 'master'],
      );
      expect(picked, 'release/2026');
    });

    test('prefers origin/main over master', () {
      final picked = BuildParameter.pickPrimaryBranch(
        '',
        ['feature/x', 'origin/main', 'master'],
      );
      expect(picked, 'origin/main');
    });

    test('falls back to *main* substring', () {
      final picked = BuildParameter.pickPrimaryBranch(
        '',
        ['feature/x', 'release/main-2026'],
      );
      expect(picked, 'release/main-2026');
    });

    test('returns first option when nothing matches', () {
      final picked = BuildParameter.pickPrimaryBranch(
        '',
        ['feature/x', 'feature/y'],
      );
      expect(picked, 'feature/x');
    });

    test('returns null on empty default + empty list', () {
      expect(BuildParameter.pickPrimaryBranch('', const []), isNull);
    });
  });
}
