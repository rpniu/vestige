// 搜索页的交互回归测试：
// 引导页 → 输入（防抖后出结果 + 条数）→ 清空回引导页 → 无结果态。
// 防抖用「等够时长」触发，不探测内部 Timer。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/search_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

void main() {
  late VestigeDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    // 搜索历史落在 shared_preferences 上，而那个 provider 默认会直接抛
    // （见 theme_provider.dart 的说明），所以每个用例都先备一份内存版偏好。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();

    db = VestigeDatabase(NativeDatabase.memory());
    final repo = RecordRepository(db.recordDao);
    await repo.addRecord(
      id: 'r1',
      title: '手冲咖啡',
      content: '今天试了水洗耶加，酸质很亮',
      tags: <String>['咖啡'],
      recordedAt: DateTime(2026, 9, 20, 9, 30),
    );
    await repo.addRecord(
      id: 'r2',
      content: '1',
      recordedAt: DateTime(2026, 9, 21, 8, 0),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const SearchScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('初始是引导页，没有结果列表', (tester) async {
    await pumpSearch(tester);
    expect(find.text('搜索所有记录'), findsOneWidget);
    expect(find.byType(RecordCard), findsNothing);
  });

  testWidgets('顶部常驻日期范围条：默认写「全部时间」，引导页上也在', (tester) async {
    await pumpSearch(tester);

    expect(find.text('全部时间'), findsOneWidget);
    // 引导页上也要有：用户可以先把时间段框好，再输入关键词
    expect(find.text('搜索所有记录'), findsOneWidget);
  });

  testWidgets('输入关键词：防抖后出结果与条数；清空回到引导页', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), '咖啡');
    // 防抖 280ms，多给一点余量
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('共 1 条结果'), findsOneWidget);
    expect(find.byType(RecordCard), findsOneWidget);
    expect(find.text('手冲咖啡'), findsOneWidget);

    // 清空输入 → 回到引导页
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('搜索所有记录'), findsOneWidget);
    expect(find.byType(RecordCard), findsNothing);
  });

  testWidgets('没有命中时显示「没有找到」', (tester) async {
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), '火箭');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('没有找到「火箭」'), findsOneWidget);
    expect(find.byType(RecordCard), findsNothing);
  });

  testWidgets('搜过的词进「最近搜索」；清空输入后能在引导页看到', (tester) async {
    await pumpSearch(tester);

    // 还没搜过 → 引导页上没有历史区
    expect(find.text('最近搜索'), findsNothing);

    await tester.enterText(find.byType(TextField), '咖啡');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 清空输入 → 回引导页，历史里应该有刚才那个词
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('最近搜索'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '咖啡'), findsOneWidget);
  });

  testWidgets('点历史 chip：把词填回输入框并再搜一次', (tester) async {
    await pumpSearch(tester);
    await tester.enterText(find.byType(TextField), '咖啡');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(InputChip, '咖啡'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '咖啡',
      reason: '点的那个词要填回输入框，用户才好接着改',
    );
    expect(find.text('共 1 条结果'), findsOneWidget);
    expect(find.byType(RecordCard), findsOneWidget);
  });

  testWidgets('历史能单条删除，也能一键清空', (tester) async {
    await pumpSearch(tester);

    for (final String q in <String>['咖啡', '水洗']) {
      await tester.enterText(find.byType(TextField), q);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputChip, '咖啡'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '水洗'), findsOneWidget);

    // 单条删除：点 chip 上的小叉
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '咖啡'),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '咖啡'), findsNothing);
    expect(find.widgetWithText(InputChip, '水洗'), findsOneWidget);

    // 一键清空
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('最近搜索'), findsNothing);
  });
}
