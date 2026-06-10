// Web / 不支持平台的空实现。
Future<void> initBuildNotifications() async {}

Future<void> showBuildResultNotification({
  required String title,
  required String body,
}) async {}

Future<bool> hasBuildNotificationPermission() async => false;

Future<bool> requestBuildNotificationPermission() async => false;

Future<void> openSystemNotificationSettings() async {}
