import 'package:flutter/material.dart';

/// 应用色板（design tokens）
///
/// 风格参考 DB-Browser：深色为主、可切换浅色；冷蓝色作为强调。
class AppColors {
  const AppColors._();

  // ---------- 深色 ----------
  static const Color darkBg = Color(0xFF0F1115);
  static const Color darkSurface = Color(0xFF171A21);
  static const Color darkSurfaceRaised = Color(0xFF1E2430);
  static const Color darkBorder = Color(0xFF2A2F3A);
  static const Color darkBorderSubtle = Color(0x10FFFFFF);
  static const Color darkSplitLine = Color(0x1AFFFFFF);
  static const Color darkText = Color(0xFFE8EAED);
  static const Color darkMuted = Color(0xFF9AA0A6);
  static const Color darkTabInactive = Color(0xFF22262E);
  static const Color darkEditorBg = Color(0xFF12141A);
  static const Color darkChromeBar = Color(0xFF161A22);
  static const Color darkHoverOverlay = Color(0x0FFFFFFF);

  // ---------- 浅色 ----------
  static const Color lightBg = Color(0xFFEEF1F6);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFF7F8FB);
  static const Color lightBorder = Color(0xFFCFD6E4);
  static const Color lightBorderSubtle = Color(0x170F1729);
  static const Color lightSplitLine = Color(0x1F0F1729);
  static const Color lightText = Color(0xFF1C2130);
  static const Color lightMuted = Color(0xFF5C6470);
  static const Color lightTabInactive = Color(0xFFE4E9F2);
  static const Color lightEditorBg = Color(0xFFF7F8FB);
  static const Color lightChromeBar = Color(0xFFE7ECF3);
  static const Color lightHoverOverlay = Color(0x0F0F1729);

  // ---------- 共享语义色 ----------
  static const Color accent = Color(0xFF4C8BF5);
  static const Color accentLight = Color(0xFF2563EB);
  static const Color success = Color(0xFF7CC79A);
  static const Color warning = Color(0xFFE7B565);
  static const Color danger = Color(0xFFE57373);
  static const Color info = Color(0xFF5DC1E6);
  static const Color running = Color(0xFFB8A0E8);
}

/// 主题扩展：应用范围内可用的语义色（不污染 ColorScheme）
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.borderSubtle,
    required this.splitLine,
    required this.text,
    required this.muted,
    required this.tabInactive,
    required this.editorBg,
    required this.chromeBar,
    required this.hoverOverlay,
    required this.accent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.running,
  });

  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color border;
  final Color borderSubtle;
  final Color splitLine;
  final Color text;
  final Color muted;
  final Color tabInactive;
  final Color editorBg;
  final Color chromeBar;
  final Color hoverOverlay;
  final Color accent;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color running;

  @override
  AppPalette copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceRaised,
    Color? border,
    Color? borderSubtle,
    Color? splitLine,
    Color? text,
    Color? muted,
    Color? tabInactive,
    Color? editorBg,
    Color? chromeBar,
    Color? hoverOverlay,
    Color? accent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? running,
  }) {
    return AppPalette(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      border: border ?? this.border,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      splitLine: splitLine ?? this.splitLine,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      tabInactive: tabInactive ?? this.tabInactive,
      editorBg: editorBg ?? this.editorBg,
      chromeBar: chromeBar ?? this.chromeBar,
      hoverOverlay: hoverOverlay ?? this.hoverOverlay,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      running: running ?? this.running,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      splitLine: Color.lerp(splitLine, other.splitLine, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      tabInactive: Color.lerp(tabInactive, other.tabInactive, t)!,
      editorBg: Color.lerp(editorBg, other.editorBg, t)!,
      chromeBar: Color.lerp(chromeBar, other.chromeBar, t)!,
      hoverOverlay: Color.lerp(hoverOverlay, other.hoverOverlay, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      running: Color.lerp(running, other.running, t)!,
    );
  }

  static const dark = AppPalette(
    bg: AppColors.darkBg,
    surface: AppColors.darkSurface,
    surfaceRaised: AppColors.darkSurfaceRaised,
    border: AppColors.darkBorder,
    borderSubtle: AppColors.darkBorderSubtle,
    splitLine: AppColors.darkSplitLine,
    text: AppColors.darkText,
    muted: AppColors.darkMuted,
    tabInactive: AppColors.darkTabInactive,
    editorBg: AppColors.darkEditorBg,
    chromeBar: AppColors.darkChromeBar,
    hoverOverlay: AppColors.darkHoverOverlay,
    accent: AppColors.accent,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    info: AppColors.info,
    running: AppColors.running,
  );

  static const light = AppPalette(
    bg: AppColors.lightBg,
    surface: AppColors.lightSurface,
    surfaceRaised: AppColors.lightSurfaceRaised,
    border: AppColors.lightBorder,
    borderSubtle: AppColors.lightBorderSubtle,
    splitLine: AppColors.lightSplitLine,
    text: AppColors.lightText,
    muted: AppColors.lightMuted,
    tabInactive: AppColors.lightTabInactive,
    editorBg: AppColors.lightEditorBg,
    chromeBar: AppColors.lightChromeBar,
    hoverOverlay: AppColors.lightHoverOverlay,
    accent: AppColors.accentLight,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    info: AppColors.info,
    running: AppColors.running,
  );
}

/// 便利扩展：`context.palette.accent`
extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}
