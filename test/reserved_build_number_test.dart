import 'package:deployment/features/release/application/release_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReservedBuildNumberRegistry', () {
    test('successive reserves under same floor return strictly increasing numbers', () {
      final registry = ReservedBuildNumberRegistry();
      final first = registry.reserve('job/a', 34);
      final second = registry.reserve('job/a', 34);
      final third = registry.reserve('job/a', 34);

      expect(first, 35);
      expect(second, 36, reason: '即使 floor 没刷新（Jenkins history 还没出新值），也要递增');
      expect(third, 37);
    });

    test('floor pushes ceiling up when history catches up', () {
      final registry = ReservedBuildNumberRegistry();
      registry.reserve('job/a', 34); // -> 35
      // 下一次 trigger 时 history 已经能看到 36（远超之前的 35），按理应继续递增
      final next = registry.reserve('job/a', 36);
      expect(next, 37);
    });

    test('per-job isolation', () {
      final registry = ReservedBuildNumberRegistry();
      expect(registry.reserve('job/a', 10), 11);
      expect(registry.reserve('job/b', 100), 101);
      expect(registry.reserve('job/a', 10), 12);
    });
  });
}
