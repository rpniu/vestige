// 统计页「年份选择」的回归测试。
//
// 盯住两件事（都是 2026-09-16 改这一块时的明确要求）：
// 1. **弹层开着时，统计页滑不动** —— 拖拽和桌面端滚轮都不行；关掉之后立刻恢复。
//    这条以前靠 `DropdownButton` 弹层自带的隐式 `ModalBarrier` 成立，
//    换成显式模态底部弹层之后它才是有意设计出来的行为，所以必须钉住。
// 2. 选完年份要真的切过去（药丸上的年份变了、弹层关掉了）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';

final int _year = DateTime.now().year;

RecordEntity _record(int i, DateTime at) => RecordEntity(
      id: 'id-$i',
      content: '第 $i 条',
      tags: const <String>[],
      recordedAt: at,
      createdAt: at,
      updatedAt: at,
      deleted: false,
    );

/// 一批「今年 + 去年」的数据，且足够让统计页真的能滚动
/// （两条卡片撑不满一屏，测「能不能滑」就没意义了）。
List<RecordEntity> _records() => <RecordEntity>[
      for (var i = 0; i < 40; i++)
        _record(
          i,
          DateTime(_year, 1 + (i % 12), 1 + (i % 27), 9, i % 60),
        ),
      _record(99, DateTime(_year - 1, 5, 5, 10)),
    ];

Future<void> _pumpStats(WidgetTester tester) async {
  // 小视口 + 两行卡片 = 页面真的能滚，否则「被挡住」和「没得滚」分不清
  tester.view.physicalSize = const Size(1080, 1920); // 360×640
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(_records()),
        ),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const StatsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _page(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// 在弹层之外、统计页之上的位置拖一把。
Future<void> _dragPage(WidgetTester tester, {double dy = -120}) async {
  await tester.dragFrom(const Offset(40, 520), Offset(0, dy));
  await tester.pumpAndSettle();
}

/// 桌面端的鼠标滚轮（用户是在 Windows 上用的，滚轮和拖拽走的是不同路径）。
Future<void> _wheelPage(WidgetTester tester) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(const Offset(40, 520));
  await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('$_year 年'));
  await tester.pumpAndSettle();
  expect(find.text('选择年份'), findsOneWidget, reason: '弹层没打开');
}

void main() {
  testWidgets('弹层开着时统计页滑不动（拖拽/滚轮都不行），关掉后立刻恢复', (tester) async {
    await _pumpStats(tester);
    final position = _page(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: '这组数据必须让统计页真的能滚动，否则这个用例什么都测不到',
    );

    await _openSheet(tester);
    final before = position.pixels;

    await _dragPage(tester);
    expect(
      position.pixels,
      before,
      reason: '弹层开着时，在弹层外的拖拽不该把统计页带着滑走',
    );

    await _wheelPage(tester);
    expect(
      position.pixels,
      before,
      reason: '弹层开着时，桌面端滚轮也不该穿到统计页上',
    );

    // 点遮罩空白处关掉弹层
    await tester.tapAt(const Offset(180, 30));
    await tester.pumpAndSettle();
    expect(find.text('选择年份'), findsNothing, reason: '点遮罩应该能关掉弹层');

    await _dragPage(tester);
    expect(
      position.pixels,
      greaterThan(before),
      reason: '弹层关掉之后统计页要立刻恢复可滚动',
    );
  });

  testWidgets('选中另一个年份：弹层关闭、药丸上的年份跟着变', (tester) async {
    await _pumpStats(tester);

    await _openSheet(tester);
    await tester.tap(find.text('${_year - 1} 年'));
    await tester.pumpAndSettle();

    expect(find.text('选择年份'), findsNothing, reason: '选完应该自动关掉弹层');
    // 弹层关了，所以这个文本只剩药丸那一处
    expect(find.text('${_year - 1} 年'), findsOneWidget);
    expect(find.text('$_year 年'), findsNothing);
  });
}
