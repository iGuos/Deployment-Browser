/// 把 [ms] 毫秒数格式化为 `mm:ss.fff` 或 `Hh mm:ss`，自适应位数。
String formatDurationMs(int ms) {
  if (ms < 0) return '--:--';
  final totalSeconds = ms ~/ 1000;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final millis = ms % 1000;
  if (h > 0) {
    return '${h}h ${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      '.${millis.toString().padLeft(3, '0')}';
}

/// 简短形式（不带毫秒）：`1h 02:03` / `12:34`
String formatDurationShort(int ms) {
  if (ms < 0) return '--:--';
  final totalSeconds = ms ~/ 1000;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  if (h > 0) {
    return '${h}h ${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
