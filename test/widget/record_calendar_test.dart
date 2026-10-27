// 统计页「记录日历」卡的交互回归测试：
// 月份标签与翻月（当月时「下个月」禁用）、补记点出现、
// 点有记录的日格弹出当天记录弹层。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _rec(
  String id,
  DateTime recordedAt, {
  DateTime? createdAt,
  String content = '1',
}) =>
    RecordEntity(
      bookId: 'default',
      id: id,
      title: null,
      content: content,
      tags: const <String>[],
      recordedAt: recordedAt,
      createdAt: createdAt ?? recordedAt,
      updatedAt: createdAt ?? recordedAt,
      deleted: false,
    );

void main() {
  Future<void> pumpStats(
    WidgetTester tester,
    List<RecordEntity> records,
  ) async {
    tester.view.physicalSize = const Size(412 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => Stream.value(records)),
        ],
        child: MaterialApp(
          theme:
              buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const StatsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('当月标签正确；「下个月」禁用；翻到上月后标签与格子都跟着变', (
    tester,
  ) async {
    final now = DateTime.now();
    await pumpStats(tester, <RecordEntity>[_rec('a', now)]);

    final thisLabel = '${now.year}年${now.month}月';
    expect(find.text(thisLabel), findsOneWidget);

    // 当月时「下个月」不可点
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(find.text(thisLabel), findsOneWidget, reason: '当月不能再往后翻');

    // 翻回上月
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();
    final prev = DateTime(now.year, now.month - 1);
    expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);
  });

  testWidgets('补记的日子带琥珀点；点日格弹出当天记录', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10, 0);
    await pumpStats(tester, <RecordEntity>[
      _rec('a', today, content: '当天记的'),
      _rec('b', today, createdAt: today.add(const Duration(days: 1)),
          content: '补记的'),
      _rec('c', today, content: '当天第二条'),
    ]);

    // 一颗补记点（只有 b 是补记）
    expect(
      find.byKey(const ValueKey<String>('calendar-backfill-dot')),
      findsOneWidget,
    );

    // 点今天这一格 → 弹出当天 3 条记录
    await tester.tap(find.text('${now.day}'));
    await tester.pumpAndSettle();
    expect(find.text('3 条'), findsOneWidget);
    expect(find.byType(RecordCard), findsNWidgets(3));
    expect(find.text('补记的'), findsOneWidget);
  });
}
