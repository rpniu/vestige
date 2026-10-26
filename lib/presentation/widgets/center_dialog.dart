import 'package:flutter/material.dart';
import 'package:vestige/app/theme.dart';

/// 居中弹层：全站模态选择的统一容器（替代原先的底部弹层）。
///
/// 为什么整体从「从下方弹出」改到居中：底部弹层把可操作的内容压在屏幕
/// 下缘 —— 标题行、行尾按钮（回退/删除）离拇指最远，列表一长还得往上
/// 够着看；居中后操作区落在视线与拇指的自然落点上，底部留白也让
/// 确认/取消类的操作更从容。
///
/// 容器之外的一切都沿用既有的「弹层统一语言」，不另起炉灶：
/// - 底色 / 圆角 / 裁剪全部来自 `dialogTheme`（`buildVestigeTheme` 里配的
///   实色卡面 + 32 圆角 + antiAlias），这里不写死任何颜色；
/// - 内容最大高度 = 屏高 × [maxHeightFactor]，超出让内容自己滚
///   （内容组件里的 `ConstrainedBox` 与此等价，取更小者，双保险）。
///   默认 0.6；行数多的选择类弹层（标签筛选 / 年份 / 操作历史）传 0.8 ——
///   列表一长，六成屏高会让用户在弹层里翻很久；
/// - 点遮罩、按返回键都可关闭，与底部弹层相同的模态语义；
/// - 内容组件照旧自带标题行（左标题 + 右侧信息/动作），本 helper 只负责容器。
///
/// [T] 是 pop 出来的结果类型（年份弹层 pop int、批量打标签 pop 结果记录等）。
Future<T?> showVestigeCenterDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxHeightFactor = 0.6,
}) {
  return showDialog<T>(
    context: context,
    builder: (BuildContext dialogContext) {
      return Dialog(
        // 手机上左右各留 20（360dp 的屏也能拿到 320 宽），平板/横屏不超过 560 ——
        // 与洞察卡「内宽 ≥520 切 4 列」的断点同量级，弹层不至于铺满大屏。
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        // 覆盖 dialogTheme 的 32 大圆角：选择类弹层要的是「一块大矩形容器」
        // 的稳定感（2026-10-22 用户反馈「外部改为一个再大一点的矩形」），
        // 24 圆角与卡片同档，轮廓更方正、内部宽度利用也更足。
        shape: RoundedRectangleBorder(borderRadius: VestigeRadius.mediumAll),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // 小内容（比如只有两三年的年份列表）也不至于缩成一条窄带。
            // 560 = 上限：桌面上是一整块铺开的矩形容器；
            // 窄屏上被 inset 夹住时自动取屏宽（Constraints 归一化会钳到外部 max）。
            minWidth: 560,
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * maxHeightFactor,
          ),
          child: builder(dialogContext),
        ),
      );
    },
  );
}
