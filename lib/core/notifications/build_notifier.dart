// 构建结束本地通知的统一入口。
//
// 通过条件导入隔离平台实现：
// - 原生平台（io）走 flutter_local_notifications；
// - Web 走 no-op stub（该插件无 Web 实现）。
import 'build_notifier_io.dart'
    if (dart.library.html) 'build_notifier_stub.dart' as impl;

/// 初始化通知（注册渠道；不主动弹权限请求）。多次调用安全。
Future<void> initBuildNotifications() => impl.initBuildNotifications();

/// 弹出一条「构建结束」通知。在不支持的平台（Web / Windows）上为 no-op。
Future<void> showBuildResultNotification({
  required String title,
  required String body,
}) =>
    impl.showBuildResultNotification(title: title, body: body);

/// 当前是否已获得系统通知权限。被拒绝 / 不支持的平台返回 false。
Future<bool> hasBuildNotificationPermission() =>
    impl.hasBuildNotificationPermission();

/// 主动向系统请求一次通知权限（仅首次弹窗有效；之后需手动到系统设置开启）。
/// 返回请求后是否已授权。
Future<bool> requestBuildNotificationPermission() =>
    impl.requestBuildNotificationPermission();

/// 打开系统「通知」设置页，引导用户手动为本应用开启通知权限。
Future<void> openSystemNotificationSettings() =>
    impl.openSystemNotificationSettings();
