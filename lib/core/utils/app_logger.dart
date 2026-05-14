import 'package:logger/logger.dart';

final appLogger = Logger(
  printer: PrettyPrinter(
    colors: false,
    methodCount: 0,
    errorMethodCount: 5,
    lineLength: 100,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    printEmojis: false,
  ),
);
