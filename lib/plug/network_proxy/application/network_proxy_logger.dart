import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef NetworkProxyLogger =
    void Function(String message, {Object? error, StackTrace? stackTrace});

final networkProxyLoggerProvider = Provider<NetworkProxyLogger>((ref) {
  return (message, {Object? error, StackTrace? stackTrace}) {
    if (error == null && stackTrace == null) {
      debugPrint(message);
      return;
    }
    debugPrint('$message error=$error stackTrace=$stackTrace');
  };
});
