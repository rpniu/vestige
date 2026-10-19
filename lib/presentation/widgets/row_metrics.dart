import 'package:flutter/material.dart';

/// 首页行高的**唯一来源**：sliver 声明行高、卡片渲染内容，两者都读这里。
///
/// 为什么需要它：`SliverList` 必须**逐个 layout 子项**才知道每行多高，所以「一线到底」
/// 这种大跨度跳转会先把中间所有行都构建 + 布局一遍、再统统丢掉 —— 成本 O(总行数)。
/// 实测 6000 条记录时，一个 320ms 的跳转动画要烧掉 5.4 秒 CPU，前几帧每帧卡 700ms。
///
/// 改成**提前声明行高**（`SliverVariedExtentList` + 这里的常量）后，跳转变成算术定位：
/// `RenderSliverFixedExtentBoxAdaptor.performLayout` 直接算出目标 index 并从那里开始布局，
/// 跳多远都只构建可见的十来行。代价就是行高必须可预知。
///
/// 所以卡片内容被限制成「标题 1 行 + 正文最多 2 行 + 元信息 1 行」，超出打省略号。
/// **修改卡片字号/行距/间距时，必须同步更新这里的常量** ——
/// `test/widget/home_fixed_row_test.dart` 会盯住「内容不许溢出给定行高」。
abstract final class VestigeRowMetrics {
  /// 卡片之间的竖直间隙。算进行高里（不放在卡片内部），这样卡片自身高度与行高严格对齐。
  static const double gap = 8;

  /// 首页左右留白。
  static const double sidePadding = 12;

  /// 卡片内边距：上下各 10。
  static const double cardPadding = 20;

  /// 卡片里「文字部分」在**未缩放**时的最大高度：
  ///
  /// 标题行 20（titleSmall 14×1.43）+ 间距 2 + 正文行 19（bodyMedium 14×1.35）
  /// + 间距 3 + 元信息行 16（labelSmall 11×1.45）= 60。
  ///
  /// 注意这是「有标题时正文只留 1 行、没标题时留 2 行」两档的上界：
  /// 两种写法的文字总高都不超过 60，所以一行高能同时套住它们。
  static const double cardTextSlot = 60;

  /// 「紧凑档」的文字高度上界：没有标题也没有元信息行时，只剩正文（最多 2 行）= 38。
  ///
  /// 这个档位是给「秒记」那种只有一行的记录用的（本 App 的主力场景：
  /// 长按 FAB 记一条 `1`）—— 一律按最坏情况的 60 算，卡片会有一半是空的。
  /// 分档的判定只看行的**形状**（有没有标题、有没有元信息），
  /// 都是 O(1) 就能算出来的事实；**不去量文字**：量文字必须和真实排版逐像素对齐，
  /// 一旦估少一行就是内容被裁，风险不划算。
  static const double denseTextSlot = 38;

  /// 一行用哪一档的文字高度。
  static double textSlot({required bool dense}) =>
      dense ? denseTextSlot : cardTextSlot;

  /// 分组头：一行文字 20 + 上 14 + 下 12。
  ///
  /// 下边距（12）特意比卡片之间的 [gap]（8）大 4px：分组头要「贴住」它下面那一天，
  /// 但和上面那一天的最后一张卡要拉开一点 —— 上下一样宽时，分组头看起来像
  /// 悬在两天之间的一句注释，而不是下面那几行的标题。
  static const double headerTextSlot = 20;
  static const double headerChrome = 26;

  /// 亚像素余量：`字号 × height` 在文本布局里可能有不到 1px 的取整误差，
  /// 留 2px 兜底，免得偶发的 0.5px 溢出把卡片顶出黄黑条纹。
  static const double slack = 2;

  /// 系统字体缩放系数（行高与卡片内的文字必须用**同一个**值，否则文字会长出行高）。
  static double textScale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1);

  /// 卡片自身高度（不含 [gap]）。[dense] 见 [denseTextSlot]。
  static double cardHeight(BuildContext context, {required bool dense}) {
    final s = textScale(context);
    return (textSlot(dense: dense) * s).ceilToDouble() + cardPadding + slack;
  }

  /// 卡片行的行高 —— 交给 sliver 声明的就是它。
  static double cardExtent(BuildContext context, {required bool dense}) =>
      cardHeight(context, dense: dense) + gap;

  /// 分组头行的行高。
  static double headerExtent(BuildContext context) {
    final s = textScale(context);
    return (headerTextSlot * s).ceilToDouble() + headerChrome + slack;
  }
}
