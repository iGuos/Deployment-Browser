import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

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
  // 初始化阶段不主动弹权限请求：默认关闭通知，权限改由用户在设置里主动授权。
  const darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
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
    _ready = true;
  } catch (e, st) {
    appLogger.w('通知初始化失败（忽略）', error: e, stackTrace: st);
    _ready = false;
  }
}

/// 查询当前系统通知权限状态（不弹窗）。
Future<bool> hasBuildNotificationPermission() async {
  if (!_supported) return false;
  await initBuildNotifications();
  if (!_ready) return false;
  try {
    if (Platform.isMacOS) {
      final opt = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.checkPermissions();
      return opt?.isEnabled ?? false;
    }
    if (Platform.isIOS) {
      final opt = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.checkPermissions();
      return opt?.isEnabled ?? false;
    }
    if (Platform.isAndroid) {
      final enabled = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.areNotificationsEnabled();
      return enabled ?? true;
    }
    // Linux 无权限模型，视为已授权。
    return true;
  } catch (e, st) {
    appLogger.w('查询通知权限失败（忽略）', error: e, stackTrace: st);
    return false;
  }
}

/// 主动请求一次系统权限；返回请求后是否已授权。
Future<bool> requestBuildNotificationPermission() async {
  if (!_supported) return false;
  await initBuildNotifications();
  if (!_ready) return false;
  try {
    if (Platform.isMacOS) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
      return ok ?? false;
    }
    if (Platform.isIOS) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
      return ok ?? false;
    }
    if (Platform.isAndroid) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return ok ?? false;
    }
    return true;
  } catch (e, st) {
    appLogger.w('请求通知权限失败（忽略）', error: e, stackTrace: st);
    return false;
  }
}

/// 打开系统「通知」设置页（macOS / iOS）。Android / Linux 退化为再次请求权限。
Future<void> openSystemNotificationSettings() async {
  try {
    if (Platform.isMacOS) {
      await launchUrl(
        Uri.parse('x-apple.systempreferences:com.apple.preference.notifications'),
      );
    } else if (Platform.isIOS) {
      await launchUrl(Uri.parse('app-settings:'));
    } else {
      // Android 无统一的设置页 URL，Linux 无权限页：退化为再次发起权限请求。
      await requestBuildNotificationPermission();
    }
  } catch (e, st) {
    appLogger.w('打开系统通知设置失败（忽略）', error: e, stackTrace: st);
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
