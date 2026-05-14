import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 让横向 [ListView] 在桌面端可用鼠标拖拽滚动（默认 Material 常排除 mouse）。
class TabBarScrollBehavior extends MaterialScrollBehavior {
  const TabBarScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

/// 将指针滚轮（竖向或横向）映射为横向 [ScrollController] 位移，便于台式机浏览超长 tab。
class HorizontalPointerScrollWrapper extends StatelessWidget {
  const HorizontalPointerScrollWrapper({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (signal) {
        if (signal is! PointerScrollEvent) return;
        if (!controller.hasClients) return;
        final d = signal.scrollDelta;
        final delta = d.dx != 0 ? d.dx : d.dy;
        if (delta == 0) return;
        final pos = controller.position;
        final next = (controller.offset + delta).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        controller.jumpTo(next);
      },
      child: ScrollConfiguration(
        behavior: const TabBarScrollBehavior(),
        child: child,
      ),
    );
  }
}

/// 带桌面友好滚动的横向列表（内部持有 [ScrollController]）。
class HorizontalScrollStrip extends StatefulWidget {
  const HorizontalScrollStrip({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
    this.physics,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  @override
  State<HorizontalScrollStrip> createState() => _HorizontalScrollStripState();
}

class _HorizontalScrollStripState extends State<HorizontalScrollStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HorizontalPointerScrollWrapper(
      controller: _controller,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        physics: widget.physics,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      ),
    );
  }
}
