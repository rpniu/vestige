import 'package:flutter/animation.dart';

/// 全站微动效的三档时长与统一曲线 —— 动效参数的唯一出处。
///
/// 之前各页面没有动效，加动效时若各自拍数字，很快就会出现
/// 120 / 200 / 250 / 300 混用、曲线各选各的局面。这里收敛成三档：
///
/// - [fast]：状态反馈类（勾选、按压、颜色过渡）——要「跟手」，必须短；
/// - [base]：内容变化类（列表展开、弹层内容入场）——看得清但不停留；
/// - [slow]：入场/图表类（柱图生长、首屏 stagger、数字滚动）——允许「表演」一次。
///
/// 曲线统一 [easeOutCubic]：快出缓停，比默认 easeIn 更「轻」，适合小幅度位移。
/// 桌面端（Windows）合成器对 filter 类动画不友好，动效只做透明度/位移/缩放。
abstract final class VestigeMotion {
  /// 状态反馈：勾选、按压、颜色过渡。
  static const Duration fast = Duration(milliseconds: 150);

  /// 内容变化：展开、弹层内容入场。
  static const Duration base = Duration(milliseconds: 220);

  /// 入场表演：柱图生长、首屏 stagger、数字滚动。
  static const Duration slow = Duration(milliseconds: 320);

  /// 统一曲线。
  static const Curve curve = Curves.easeOutCubic;
}
