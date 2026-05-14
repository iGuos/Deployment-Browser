import 'package:flutter/widgets.dart';

/// 响应式断点。
///
/// - mobile：< 720（手机竖屏 / 大手机）
/// - tablet：720 – 1100（小桌面 / 平板）
/// - desktop：>= 1100（标准桌面工作区）
class Breakpoints {
  const Breakpoints._();

  static const double mobile = 720;
  static const double tablet = 1100;
}

enum ScreenKind { mobile, tablet, desktop }

extension ScreenKindContext on BuildContext {
  ScreenKind get screenKind {
    final width = MediaQuery.sizeOf(this).width;
    if (width < Breakpoints.mobile) return ScreenKind.mobile;
    if (width < Breakpoints.tablet) return ScreenKind.tablet;
    return ScreenKind.desktop;
  }

  bool get isDesktop => screenKind == ScreenKind.desktop;
  bool get isMobile => screenKind == ScreenKind.mobile;
  bool get isTablet => screenKind == ScreenKind.tablet;

  /// 桌面 + 平板共用「sidebar 风格」布局
  bool get isWide => screenKind != ScreenKind.mobile;
}
