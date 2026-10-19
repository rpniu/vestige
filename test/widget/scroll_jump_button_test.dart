import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/presentation/widgets/scroll_jump_button.dart';

/// 滑动跳转按钮的回归测试。
///
/// 这里专门盯住一个曾经出现过的 bug：**方向翻转时没有触发重建**，
/// 于是图标还停在上一帧（比如仍显示「到顶」），可点下去已经变成「到底」了 ——
/// 用户看到的就是「图标和功能不一致」。所以断言要同时覆盖
/// 「图标是哪个」和「点完去了哪里」，只测一个都抓不住这个问题。
void main() {
  /// 造一个能滚动 100 项的列表 + 跳转按钮，返回它的 ScrollController。
  /// [hideDelay] 默认给得很长（这些用例要的是「按钮还在」，不是自动隐藏），
  /// 只有专门的自动隐藏用例才传短值。
  Future<ScrollController> pumpList(
    WidgetTester tester, {
    Duration hideDelay = const Duration(minutes: 5),
  }) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ListView.builder(
                controller: controller,
                itemCount: 100,
                itemBuilder: (context, index) => SizedBox(
                  height: 50,
                  child: Text('item $index'),
                ),
              ),
              Positioned(
                right: 14,
                bottom: 88,
                child: ScrollJumpButton(
                  controller: controller,
                  hideDelay: hideDelay,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return controller;
  }

  /// 按钮的显隐状态：AnimatedOpacity 的 opacity（1 = 显示中，0 = 已隐藏）。
  /// 隐藏时 widget 仍在树上（只是透明 + IgnorePointer），所以不能用 byIcon 判显隐。
  double buttonOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(ScrollJumpButton),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('中间区域：向上滑动显示「到底」，点击后真的走到尾', (tester) async {
    final controller = await pumpList(tester);

    // 手指向上推 = 往下翻（看更早的记录）
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(buttonOpacity(tester), 1);
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(find.byIcon(Icons.vertical_align_top), findsNothing);

    await tester.tap(find.byType(ScrollJumpButton));
    await tester.pumpAndSettle();

    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('方向翻转后图标立即跟着变，且点击去向与新图标一致', (tester) async {
    final controller = await pumpList(tester);

    // 先往下翻一段（此时应是「到底」）
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);

    // 再往回滑（手指向下拖 = offset 变小）→ 图标必须翻成「到顶」
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.vertical_align_top),
      findsOneWidget,
      reason: '方向翻转时必须重建，否则图标会停在上一帧',
    );
    expect(find.byIcon(Icons.vertical_align_bottom), findsNothing);

    // 点下去应该回到顶部 —— 与新图标一致
    expect(controller.offset, greaterThan(0));
    await tester.tap(find.byType(ScrollJumpButton));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
  });

  testWidgets('滑回顶部后按钮显示「到底」，点击直达末尾', (tester) async {
    final controller = await pumpList(tester);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);

    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(find.byIcon(Icons.vertical_align_top), findsNothing);

    await tester.tap(find.byType(ScrollJumpButton));
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('列表长度不足（没得滚）时按钮保持隐藏', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              ListView(
                controller: controller,
                children: const <Widget>[
                  SizedBox(height: 40, child: Text('only one')),
                ],
              ),
              Positioned(
                right: 14,
                bottom: 88,
                child: ScrollJumpButton(
                  controller: controller,
                  hideDelay: const Duration(minutes: 5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(buttonOpacity(tester), 0);
  });

  testWidgets('停手后按 hideDelay 自动淡出', (tester) async {
    await pumpList(tester, hideDelay: const Duration(milliseconds: 300));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    expect(buttonOpacity(tester), 1);

    // 越过 hideDelay，按钮应自动隐藏
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 0);
  });
}
