import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条异常记录。
@immutable
class ErrorLogEntry {
  const ErrorLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;

  /// 'error' / 'warning' / 'fatal'，用于在 UI 上区分严重程度。
  final String level;
  final String message;
  final String? error;
  final String? stackTrace;

  Map<String, dynamic> toJson() => {
        't': timestamp.toIso8601String(),
        'l': level,
        'm': message,
        if (error != null) 'e': error,
        if (stackTrace != null) 's': stackTrace,
      };

  static ErrorLogEntry? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final ts = DateTime.tryParse(m['t'] as String? ?? '');
    if (ts == null) return null;
    return ErrorLogEntry(
      timestamp: ts,
      level: (m['l'] as String?) ?? 'error',
      message: (m['m'] as String?) ?? '',
      error: m['e'] as String?,
      stackTrace: m['s'] as String?,
    );
  }
}

/// 应用异常日志服务。
///
/// 由全局错误处理器（[FlutterError.onError] / [PlatformDispatcher.onError]）
/// 以及 [appLogger] 的 warning / error / fatal 输出共同写入；UI 通过
/// [ChangeNotifier] 订阅刷新。最近 [maxEntries] 条会持久化到
/// [SharedPreferences]，供下次启动查看。
class ErrorLogService extends ChangeNotifier {
  ErrorLogService({this.maxEntries = 200});

  final int maxEntries;
  static const _kPrefsKey = 'app.error_log.entries_v1';

  final List<ErrorLogEntry> _entries = <ErrorLogEntry>[];
  SharedPreferences? _prefs;
  bool _loaded = false;

  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);

  /// 应用启动后绑定持久化层，加载历史记录。
  Future<void> bind(SharedPreferences prefs) async {
    if (_loaded && identical(_prefs, prefs)) return;
    _prefs = prefs;
    final raw = prefs.getString(_kPrefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final entry = ErrorLogEntry.tryFromJson(item);
            if (entry != null) _entries.add(entry);
          }
        }
      } catch (_) {
        // 反序列化失败时静默忽略，不希望日志服务自身炸到日志服务里。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  void record({
    required String level,
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = ErrorLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      error: error?.toString(),
      stackTrace: stackTrace?.toString(),
    );
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    if (_entries.isEmpty) return;
    _entries.clear();
    await _prefs?.remove(_kPrefsKey);
    notifyListeners();
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    final encoded = jsonEncode(_entries.map((e) => e.toJson()).toList());
    // 注意：SharedPreferences.setString 返回 Future，但这里用 fire-and-forget
    // 即可，UI 已经基于内存状态刷新。
    unawaited(prefs.setString(_kPrefsKey, encoded));
  }
}

/// 全局单例，全局错误处理与 logger 都可直接调用。
final ErrorLogService errorLogService = ErrorLogService();

/// 把异常落入全局日志（捕获后写入服务 + 同步打到 appLogger，便于 console 查看）。
void recordAppException(
  String message, {
  Object? error,
  StackTrace? stackTrace,
  String level = 'error',
}) {
  errorLogService.record(
    level: level,
    message: message,
    error: error,
    stackTrace: stackTrace,
  );
}

/// 把 [appLogger] 的 warning / error / fatal 输出转发到 [ErrorLogService]。
class ErrorLogLoggerOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    if (event.level.value < Level.warning.value) return;
    final origin = event.origin;
    final level = switch (origin.level) {
      Level.warning => 'warning',
      Level.fatal => 'fatal',
      _ => 'error',
    };
    errorLogService.record(
      level: level,
      message: origin.message?.toString() ?? '',
      error: origin.error,
      stackTrace: origin.stackTrace,
    );
  }
}

