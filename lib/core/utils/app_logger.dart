import 'package:logger/logger.dart';

import 'error_log_service.dart';

final appLogger = Logger(
  printer: PrettyPrinter(
    colors: false,
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 100,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    printEmojis: false,
  ),
  // 控制台输出保留；warning / error / fatal 同时入异常日志，供「设置 → 异常日志」查看。
  output: MultiOutput([ConsoleOutput(), ErrorLogLoggerOutput()]),
);
