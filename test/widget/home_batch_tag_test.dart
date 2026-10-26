// 首页「批量打标签」入口的回归测试。
//
// 钉住三件事：
// 1. 多选后能从 AppBar 打开弹层，弹层里列出已有标签；
// 2. 什么都没选时两个按钮都是灰的 —— 不能拿着空标签去跑一次批量写；
// 3. 只填「新标签」输入框、不勾任何 chip 时，「加上这些」可用而「去掉这些」仍灰
//    （还不存在的标签没什么可去掉的）。

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

/// 长按进多选，再点 AppBar 上的「批量打标签」把弹层打开。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.longPress(find.byType(RecordCard).first);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('批量打标签'));
  await tester.pumpAndSettle();
}

VoidCallback? _filledOnPressed(WidgetTester tester, String label) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, label))
    .onPressed;

VoidCallback? _outlinedOnPressed(WidgetTester tester, String label) => tester
    .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
    .onPressed;

void main() {
  testWidgets('打开弹层：列出已有标签；没选标签时两个按钮都置灰', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today, tags: <String>['运动']),
      _rec('b', _today, tags: <String>['读书']),
    ]);
    await _openSheet(tester);

    expect(find.text('给选中的 1 条打标签'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '#运动'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '#读书'), findsOneWidget);

    expect(_filledOnPressed(tester, '加上这些'), isNull);
    expect(_outlinedOnPressed(tester, '去掉这些'), isNull);

    // 勾一个 chip → 两个按钮都能点了
    await tester.tap(find.widgetWithText(FilterChip, '#读书'));
    await tester.pumpAndSettle();
    expect(_filledOnPressed(tester, '加上这些'), isNotNull);
    expect(_outlinedOnPressed(tester, '去掉这些'), isNotNull);
  });

  testWidgets('只填新标签、不勾 chip：「加上这些」可用，但「去掉这些」仍灰', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today, tags: <String>['运动']),
      _rec('b', _today),
    ]);
    await _openSheet(tester);

    await tester.enterText(find.byType(TextField), '旅行');
    await tester.pumpAndSettle();

    expect(_filledOnPressed(tester, '加上这些'), isNotNull);
    expect(
      _outlinedOnPressed(tester, '去掉这些'),
      isNull,
      reason: '还不存在的标签没什么可去掉的',
    );
  });

  testWidgets('点「加上这些」会关掉弹层', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today, tags: <String>['运动']),
      _rec('b', _today),
    ]);
    await _openSheet(tester);

    await tester.tap(find.widgetWithText(FilterChip, '#运动'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '加上这些'));
    await tester.pumpAndSettle();

    expect(find.text('给选中的 1 条打标签'), findsNothing);
  });

  testWidgets('「已选 0 条」时批量打标签按钮置灰', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _rec('a', _today, tags: <String>['运动']),
      _rec('b', _today),
    ]);
    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    // 点全选框全选，再点一次清空 → 0 选中，但多选态还在
    final box = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(Checkbox),
    );
    await tester.tap(box);
    await tester.pumpAndSettle();
    await tester.tap(box);
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);

    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.sell_rounded),
          )
          .onPressed,
      isNull,
    );
  });
}
