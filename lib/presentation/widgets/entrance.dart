import 'package:flutter/material.dart';
import 'package:vestige/app/motion.dart';

/// 一次性入场动效：淡入 + 8px 上移，可带 stagger 延迟。
///
/// 首页首屏前几行、弹层列表首屏项共用。用 [TweenAnimationBuilder] 驱动
/// （无需 AnimationController），只在首次构建时播放 —— tween 的 end 恒为 1，
/// 之后的普通重建不会重播，列表滚动复用也只会播放一次。
///
/// **只动透明度与位移，不参与布局**：外层（如首页 `SliverVariedExtentList`）
/// 声明的行高不受影响，`Opacity` 与 `Transform.translate` 都不改变占位尺寸。
class VestigeEntrance extends StatelessWidget {
  const VestigeEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;

  /// stagger 延迟：同一屏的多个条目按 index 递增 20~30ms，
  /// 形成「从上往下依次浮现」的层次。超过 8 个条目不建议再加大延迟。
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: VestigeMotion.slow + delay,
      curve: VestigeMotion.curve,
      builder: (context, t, _) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}
