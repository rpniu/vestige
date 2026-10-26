// 首页记录多选 + 全选的回归测试。
//
// 背景（2026-09-22）：首页原先多选态左侧是「取消选择」的 ×，没有全选。
// 现在左侧换成**三态全选框**（取消选择挪到 actions 末尾）。
//
// 关键语义：全选的候选集是 **当前列表里可见的记录**（`homeRowsProvider`），
// 而不是全库 —— 标签筛选生效时，「全选」只选筛出来的那些。
// 这一条必须钉住：批量删除不可逆，多选一个用户没看见的记录就是事故。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _rec(
  String id,
  DateTime day, {
  List<String> tags = const <String>[],
}) =>
    RecordEntity(
      id: id,
      title: null,
      content: '第 $id 条',
      tags: tags,
      recordedAt: day,
      createdAt: day,
      updatedAt: day,
      deleted: false,
    );

final DateTime _today = DateTime.now();

/// 首页 AppBar 左侧那个全选框（多选态才出现，在 leading 里）。
Finder _selectAllBox() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(Checkbox),
    );

Future<void> _pumpHome(WidgetTester tester, List<RecordEntity> records) async {
  tester.view.physicalSize = const Size(412 * 3, 892 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => Stream.value(records)),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未进入多选时 AppBar 上没有全选框；长按一条才出现（部分选中态）', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today),
      _rec('b', _today.subtract(const Duration(days: 1))),
      _rec('c', _today.subtract(const Duration(days: 2))),
    ]);

    expect(_selectAllBox(), findsNothing);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    expect(find.text('已选 1 条'), findsOneWidget);
    expect(_selectAllBox(), findsOneWidget);
    expect(tester.widget<Checkbox>(_selectAllBox()).value, isNull);
  });

  testWidgets('点全选框全选 3 条，再点一次只清勾选、**不退出多选态**', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today),
      _rec('b', _today.subtract(const Duration(days: 1))),
      _rec('c', _today.subtract(const Duration(days: 2))),
    ]);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    // 部分选中 → 全选
    await tester.tap(_selectAllBox());
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget);
    expect(tester.widget<Checkbox>(_selectAllBox()).value, isTrue);

    // 已全选 → 再点一次 = 只清勾选。
    // 多选态**留着**：标题变「已选 0 条」、全选框还在（回落到全不选）、FAB 仍隐藏。
    // 用户点它是想清掉这批重新挑，把他踢出多选就得重新长按一次。
    await tester.tap(_selectAllBox());
    await tester.pumpAndSettle();
    expect(_selectAllBox(), findsOneWidget);
    expect(tester.widget<Checkbox>(_selectAllBox()).value, isFalse);
    expect(find.text('已选 0 条'), findsOneWidget);
    // FAB 已改成 56×56 正方形、只留「+」图标（和「到顶/到底」按钮等大），
    // 不再有「记一笔」文字，所以这里按类型断言。
    expect(find.byType(FloatingActionButton), findsNothing);

    // 0 选中时三个批量按钮必须置灰，否则会拿着空 id 列表跑一遍
    VoidCallback? actionOf(IconData icon) => tester
        .widget<IconButton>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.widgetWithIcon(IconButton, icon),
          ),
        )
        .onPressed;
    expect(actionOf(Icons.keyboard_double_arrow_left_rounded), isNull, reason: '0 选中时「日期减一天」应置灰');
    expect(actionOf(Icons.keyboard_double_arrow_right_rounded), isNull, reason: '0 选中时「日期加一天」应置灰');
    expect(actionOf(Icons.delete_rounded), isNull, reason: '0 选中时「移入回收站」应置灰');

    // 「取消选择」才是退出多选的出口
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(_selectAllBox(), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('手动取消勾选最后一条：同样只清勾选，不退出多选态', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today),
      _rec('b', _today.subtract(const Duration(days: 1))),
    ]);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    // 多选态下再点这张卡片 = 取消勾选。和「取消全选」是同一个语义，结果也必须一样。
    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    expect(find.text('已选 0 条'), findsOneWidget);
    expect(_selectAllBox(), findsOneWidget);
    expect(tester.widget<Checkbox>(_selectAllBox()).value, isFalse);
  });

  testWidgets('全选的候选集只看**当前可见**：标签筛选后全选只选筛出来的那些', (tester) async {
    // 4 条：3 条带「咖啡」，1 条不带
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today, tags: <String>['咖啡']),
      _rec('b', _today.subtract(const Duration(days: 1)), tags: <String>['咖啡']),
      _rec('c', _today.subtract(const Duration(days: 2)), tags: <String>['咖啡']),
      _rec('d', _today.subtract(const Duration(days: 3))),
    ]);
    expect(find.byType(RecordCard), findsNWidgets(4));

    // 先按「咖啡」筛选 → 只剩 3 条
    await tester.tap(find.byTooltip('按标签筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '#咖啡'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(RecordCard), findsNWidgets(3));

    // 长按进多选 → 全选 → 只该选到筛出来的 3 条，不是 4 条
    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(_selectAllBox());
    await tester.pumpAndSettle();

    expect(
      find.text('已选 3 条'),
      findsOneWidget,
      reason: '被标签筛掉的那条不该被全选进来（批量删除不可逆）',
    );
  });

  testWidgets('全选后批量平移日期：按钮可用（选中数正确）', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today),
      _rec('b', _today.subtract(const Duration(days: 1))),
    ]);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(_selectAllBox());
    await tester.pumpAndSettle();

    expect(find.byTooltip('日期加一天'), findsOneWidget);
    expect(find.byTooltip('日期减一天'), findsOneWidget);
    expect(find.byTooltip('移入回收站'), findsOneWidget);
    // 批量操作执行后选中态清空
    await tester.tap(find.byTooltip('日期加一天'));
    await tester.pumpAndSettle();
    expect(_selectAllBox(), findsNothing);
  });

  testWidgets('「取消选择」按钮挪到了 actions 末尾，仍可用', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today),
      _rec('b', _today.subtract(const Duration(days: 1))),
    ]);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();

    expect(_selectAllBox(), findsNothing);
    expect(find.text('已选 1 条'), findsNothing);
  });
}
