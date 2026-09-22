import 'package:flutter/material.dart';

/// 「发版中」的呼吸动效：明暗交替 + 轻微缩放。
///
/// 包住状态图标或状态点即可——静态色之外一眼能看出这一路还在跑。
/// [Transform.scale] 不改变布局尺寸，所在的行 / 标签不会跟着抖。
class BuildingPulse extends StatefulWidget {
  const BuildingPulse({
    super.key,
    required this.child,
    this.minOpacity = 0.45,
    this.minScale = 0.88,
    this.maxScale = 1.1,
    this.period = const Duration(milliseconds: 900),
  });

  final Widget child;
  final double minOpacity;
  final double minScale;
  final double maxScale;
  final Duration period;

  @override
  State<BuildingPulse> createState() => _BuildingPulseState();
}

class _BuildingPulseState extends State<BuildingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat(reverse: true);

  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = _pulse.value;
        return Opacity(
          opacity: widget.minOpacity + (1 - widget.minOpacity) * t,
          child: Transform.scale(
            scale: widget.minScale + (widget.maxScale - widget.minScale) * t,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
