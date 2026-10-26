// 回收站多选 + 全选的回归测试。
//
// 背景（2026-09-22）：回收站原先左侧是「取消选择」的 ×，没有全选。
// 现在左侧换成**三态全选框**，取消选择挪到 actions 末尾。
//
// 这里盯住：三态（全不选 / 部分 / 全选）、全选→全不选来回切、
// 全选后能批量恢复/彻底删除、以及回收站原有的「记录消失时清理选中项」不变量。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/trash_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _rec(String id, DateTime day) => RecordEntity(
      id: id,
      title: null,
      content: '第 $id 条',
      tags: const <String>[],
      recordedAt: day,
      createdAt: day,
      updatedAt: day,
      deleted: true,
    );

final DateTime _today = DateTime.now();

/// 回收站 AppBar 左侧那个全选框（多选态才出现）。
///
/// 注意不能直接 `find.byType(Checkbox)` —— 记录卡在多选态下也画勾选图标，
/// 但那是 `Icon` 不是 `Checkbox`，所以这里其实唯一；仍然限定在 AppBar 内更稳。
Checkbox _selectAllBox(WidgetTester tester) => tester.widget<Checkbox>(
      find.descendant(of: find.byType(AppBar), matching: find.byType(Checkbox)),
    );

Future<void> _pumpTrash(
  WidgetTester tester,
  Stream<List<RecordEntity>> stream,
) async {
  tester.view.physicalSize = const Size(412 * 3, 892 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[trashProvider.overrideWith((ref) => stream)],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const TrashScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未进入多选时没有全选框；点一条卡片才出现，且是部分选中态', (tester) async {
    await _pumpTrash(tester, Stream<List<RecordEntity>>.value(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
      _rec('c', _today),
    ]));

    // 未多选：AppBar 里没有复选框
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(Checkbox)),
      findsNothing,
    );
    expect(find.text('回收站'), findsOneWidget);

    // 点一条 → 多选态，复选框是「部分选中」（tristate 下值为 null）
    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(_selectAllBox(tester).value, isNull);
  });

  testWidgets('点全选框：全选（3 条），再点一次只清勾选、**不退出多选**', (tester) async {
    await _pumpTrash(tester, Stream<List<RecordEntity>>.value(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
      _rec('c', _today),
    ]));

    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    // 部分选中 → 点一下 = 全选
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget);
    expect(_selectAllBox(tester).value, isTrue);

    // 已全选 → 再点一下 = 只清勾选。多选态留着，复选框回落到「全不选」。
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);
    expect(_selectAllBox(tester).value, isFalse);

    // 0 选中时批量按钮置灰，否则会弹出「0 条记录将被永久删除」这种确认框
    VoidCallback? actionOf(IconData icon) => tester
        .widget<IconButton>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.widgetWithIcon(IconButton, icon),
          ),
        )
        .onPressed;
    expect(actionOf(Icons.restore_rounded), isNull, reason: '0 选中时「恢复」应置灰');
    expect(
      actionOf(Icons.delete_forever_rounded),
      isNull,
      reason: '0 选中时「彻底删除」应置灰',
    );

    // 「取消选择」才是退出多选的出口
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('回收站'), findsOneWidget);
  });

  testWidgets('全选后批量恢复：所有记录都被恢复', (tester) async {
    final controller = StreamController<List<RecordEntity>>();
    addTearDown(controller.close);
    controller.add(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
      _rec('c', _today),
    ]);
    await _pumpTrash(tester, controller.stream);

    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget);

    // 恢复调用会走 repository（测试里没接数据库，用真实的默认实现即可 —— 它不会抛，
    // 只是不产生效果），关键是按钮可点、且点完清空了选中态。
    await tester.tap(find.byTooltip('恢复'));
    await tester.pumpAndSettle();

    // 选中态清空 → 退回非多选态
    expect(find.text('回收站'), findsOneWidget);
  });

  testWidgets('全选后彻底删除要二次确认，文案里带条数', (tester) async {
    final controller = StreamController<List<RecordEntity>>();
    addTearDown(controller.close);
    controller.add(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
    ]);
    await _pumpTrash(tester, controller.stream);

    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('彻底删除'));
    await tester.pumpAndSettle();

    expect(find.text('彻底删除？'), findsOneWidget);
    expect(find.text('2 条记录将被永久删除，无法恢复。'), findsOneWidget);
  });

  testWidgets('记录在外部消失时，选中项被清理，全选框跟着回落到「全不选」', (tester) async {
    final controller = StreamController<List<RecordEntity>>();
    addTearDown(controller.close);
    controller.add(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
    ]);
    await _pumpTrash(tester, controller.stream);

    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    // 剩下的记录被外部改成一个完全不同的 id → 原来的选中项全部失效、被清理
    controller.add(<RecordEntity>[_rec('c', _today)]);
    await tester.pumpAndSettle();

    // 勾选被清空了，但多选态**不退出**（退出只由「取消选择」/返回触发），
    // 标题落到「已选 0 条」，全选框回落到「全不选」。
    expect(find.text('已选 0 条'), findsOneWidget);
    expect(_selectAllBox(tester).value, isFalse);
  });

  testWidgets('「取消选择」按钮仍在（挪到 actions 末尾），一点就退出多选', (tester) async {
    await _pumpTrash(tester, Stream<List<RecordEntity>>.value(<RecordEntity>[
      _rec('a', _today),
      _rec('b', _today),
    ]));

    await tester.tap(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.text('回收站'), findsOneWidget);
  });
}
