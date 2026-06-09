import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/app_logger.dart';

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;
int _nextId = 1;

// flutter_local_notifications 支持 Android / iOS / macOS / Linux；Windows 无实现。
bool get _supported =>
    Platform.isMacOS || Platform.isIOS || Platform.isAndroid || Platform.isLinux;

const _androidChannelId = 'build_results';

Future<void> initBuildNotifications() async {
  if (!_supported || _ready) return;
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwin = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: false,
    requestSoundPermission: true,
  );
  const linux = LinuxInitializationSettings(defaultActionName: 'Open');
  const settings = InitializationSettings(
    android: android,
    iOS: darwin,
    macOS: darwin,
    linux: linux,
  );
  try {
    await _plugin.initialize(settings: settings);
    // 主动请求权限：iOS / macOS / Android 13+。
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  } catch (e, st) {
    appLogger.w('通知初始化失败（忽略）', error: e, stackTrace: st);
    _ready = false;
  }
}

Future<void> showBuildResultNotification({
  required String title,
  required String body,
}) async {
  if (!_supported) return;
  if (!_ready) await initBuildNotifications();
  if (!_ready) return;
  const android = AndroidNotificationDetails(
    _androidChannelId,
    '构建结果',
    channelDescription: '构建完成 / 失败时通知',
    importance: Importance.high,
    priority: Priority.high,
  );
  const darwin = DarwinNotificationDetails();
  const linux = LinuxNotificationDetails();
  const details = NotificationDetails(
    android: android,
    iOS: darwin,
    macOS: darwin,
    linux: linux,
  );
  try {
    final id = _nextId++ & 0x7fffffff;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  } catch (e, st) {
    appLogger.w('通知发送失败（忽略）', error: e, stackTrace: st);
  }
}
