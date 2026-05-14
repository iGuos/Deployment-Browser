import 'package:deployment/features/jenkins/domain/jenkins_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeBuildStagesForRunning', () {
    test('empty template returns live', () {
      final live = [
        const BuildStage(id: '1', name: 'A', status: 'SUCCESS', durationMillis: 10),
      ];
      expect(mergeBuildStagesForRunning(const [], live), live);
    });

    test('empty live yields all NOT_EXECUTED from template', () {
      final template = [
        const BuildStage(id: '10', name: 'Checkout', status: 'SUCCESS', durationMillis: 1),
        const BuildStage(id: '11', name: 'Deploy', status: 'SUCCESS', durationMillis: 2),
      ];
      final merged = mergeBuildStagesForRunning(template, const []);
      expect(merged.length, 2);
      expect(merged[0].name, 'Checkout');
      expect(merged[0].status, 'NOT_EXECUTED');
      expect(merged[1].name, 'Deploy');
      expect(merged[1].status, 'NOT_EXECUTED');
    });

    test('overlays live by stage name and keeps template order', () {
      final template = [
        const BuildStage(id: 't1', name: 'A', status: 'SUCCESS', durationMillis: 0),
        const BuildStage(id: 't2', name: 'B', status: 'SUCCESS', durationMillis: 0),
        const BuildStage(id: 't3', name: 'C', status: 'SUCCESS', durationMillis: 0),
      ];
      final live = [
        const BuildStage(id: 'x', name: 'A', status: 'SUCCESS', durationMillis: 100),
        const BuildStage(id: 'y', name: 'B', status: 'IN_PROGRESS', durationMillis: 0),
      ];
      final merged = mergeBuildStagesForRunning(template, live);
      expect(merged.length, 3);
      expect(merged[0].status, 'SUCCESS');
      expect(merged[1].status, 'IN_PROGRESS');
      expect(merged[2].name, 'C');
      expect(merged[2].status, 'NOT_EXECUTED');
    });

    test('appends live-only stages not in template', () {
      final template = [
        const BuildStage(id: 't1', name: 'A', status: 'SUCCESS', durationMillis: 0),
      ];
      final live = [
        const BuildStage(id: 'x', name: 'A', status: 'SUCCESS', durationMillis: 1),
        const BuildStage(id: 'z', name: 'New', status: 'IN_PROGRESS', durationMillis: 0),
      ];
      final merged = mergeBuildStagesForRunning(template, live);
      expect(merged.length, 2);
      expect(merged[1].name, 'New');
    });
  });
}
