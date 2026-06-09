import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 顶部居中的浮层 Toast。
///
/// 插入 **root overlay**，因此始终盖在对话框/遮罩之上;淡入 → 停留 → 淡出后自动移除。
/// 适合在弹框内做「已复制 / 已保存」这类轻提示(默认 3 秒)。
void showTopToast(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final palette = context.palette;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TopToast(
      message: message,
      palette: palette,
      isError: isError,
      duration: duration,
      onDismiss: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _TopToast extends StatefulWidget {
  const _TopToast({
    required this.message,
    required this.palette,
    required this.isError,
    required this.duration,
    required this.onDismiss,
  });

  final String message;
  final AppPalette palette;
  final bool isError;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _c.forward();
    await Future<void>.delayed(widget.duration);
    if (!mounted) return;
    await _c.reverse();
    widget.onDismiss();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final accent = widget.isError ? p.danger : p.success;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 24,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _c,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, -0.25), end: Offset.zero)
                  .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 460),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  decoration: BoxDecoration(
                    color: p.surfaceRaised,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.borderSubtle),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.20),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                        size: 15,
                        color: accent,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(color: p.text, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
