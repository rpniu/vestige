import 'package:flutter/material.dart';
import 'package:vestige/presentation/widgets/undo_history_sheet.dart';

/// 操作历史页（独立屏幕）。
///
/// 之前它是「我的 → 操作历史」打开的一个居中弹层；改成整页的原因：
/// 弹层高度再大也只有屏高八成（见 `showVestigeCenterDialog` 的 maxHeightFactor），
/// 历史一长就要在一个小框里滚动，且弹层里再叠确认框容易出现「层压层」的观感。
/// 整页之后列表能吃满屏高，滚动、返回、系统手势都回到页面级语义。
///
/// AppBar 只承担「返回」：标题与「清空」仍在内容组件（[UndoHistorySheet]）
/// 自己的标题行里 —— 这样弹层时期的内容布局与交互一行都不改，
/// 页面外壳只负责给一块整屏的承载空间。若这里再写一遍标题，
/// 屏幕上就会出现两行「操作历史」。
class UndoHistoryScreen extends StatelessWidget {
  const UndoHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 无标题的 AppBar：只出返回箭头。用 toolbarHeight 收窄一点，
      // 让内容更快进入视线（这页没有需要强调的页面级标题）。
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: 0,
      ),
      body: const UndoHistorySheet(),
    );
  }
}
