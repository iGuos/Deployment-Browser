// 构建结束本地通知的统一入口。
//
// 通过条件导入隔离平台实现：
// - 原生平台（io）走 flutter_local_notifications；
// - Web 走 no-op stub（该插件无 Web 实现）。
import 'build_notifier_io.dart'
    if (dart.library.html) 'build_notifier_stub.dart' as impl;

/// 初始化通知（请求权限、注册渠道）。多次调用安全。
Future<void> initBuildNotifications() => impl.initBuildNotifications();

/// 弹出一条「构建结束」通知。在不支持的平台（Web / Windows）上为 no-op。
Future<void> showBuildResultNotification({
  required String title,
  required String body,
}) =>
    impl.showBuildResultNotification(title: title, body: body);
