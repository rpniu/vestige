// 主页标题的回归测试。
//
// 背景（2026-09-17）：标题原来写的是 App 名「Vestige」—— 对每天都打开的人零信息量。
// 换成「今天是哪天 + 距离上次记录多久」：第一行是时间锚点，第二行是提醒。
//
// 这里盯住：日期文案、三种间隔（今天已记录 / N 天 / 还没有记录）、
// 以及**选中模式下标题要让位给「已选 N 条」**。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _record(String id, DateTime day) => RecordEntity(
      bookId: 'default',
      id: id,
      content: '第 $id 条',
      tags: const <String>[],
      recordedAt: DateTime(day.year, day.month, day.day, 9),
      createdAt: DateTime(day.year, day.month, day.day, 9),
      updatedAt: day,
      deleted: false,
    );

/// 相对「今天」的第 [offset] 天（0 = 今天）。
DateTime _dayOffset(int offset) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - offset);
}

Future<void> _pumpHome(WidgetTester tester, List<RecordEntity> records) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(records),
        ),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('标题第一行是今天的年月日加星期，不再显示 App 名', (tester) async {
    await _pumpHome(tester, <RecordEntity>[_record('a', _dayOffset(0))]);

    expect(find.text(fullDateLabel(DateTime.now())), findsOneWidget);
    expect(find.text('Vestige'), findsNothing);
  });

  testWidgets('最近一次就是今天 → 「今天已记录」', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _record('a', _dayOffset(0)),
      _record('b', _dayOffset(5)),
    ]);

    expect(find.text('今天已记录'), findsOneWidget);
  });

  testWidgets('最近一次是 3 天前 → 「距上次记录 3 天」（按业务日期算，不看入库时间）', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _record('a', _dayOffset(3)),
      _record('b', _dayOffset(9)),
    ]);

    expect(find.text('距上次记录 3 天'), findsOneWidget);
  });

  testWidgets('补记：业务日期是今天就算「今天已记录」，即使它是三天后才补交的', (tester) async {
    final now = DateTime.now();
    await _pumpHome(tester, <RecordEntity>[
      RecordEntity(
        bookId: 'default',
        id: 'backfilled',
        content: '1',
        tags: const <String>[],
        recordedAt: DateTime(now.year, now.month, now.day, 8),
        // 入库时间在三天后（补记），业务日期仍是今天
        createdAt: DateTime(now.year, now.month, now.day + 3, 8),
        updatedAt: now,
        deleted: false,
      ),
    ]);

    expect(find.text('今天已记录'), findsOneWidget);
  });

  testWidgets('一条记录都没有 → 「还没有记录」，但日期照常显示', (tester) async {
    await _pumpHome(tester, const <RecordEntity>[]);

    expect(find.text('还没有记录'), findsOneWidget);
    expect(find.text(fullDateLabel(DateTime.now())), findsOneWidget);
    expect(find.text('还没有任何记录'), findsOneWidget); // 空状态本身还在
  });

  testWidgets('AppBar 右侧只剩一个展开按钮，点开列出各功能', (tester) async {
    await _pumpHome(tester, <RecordEntity>[_record('a', _dayOffset(0))]);

    // 单个图标按钮（⋮），其余入口不再平铺
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('搜索'), findsNothing);
    expect(find.byTooltip('回收站'), findsNothing);
    expect(find.byIcon(Icons.delete_sweep_rounded), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 菜单里是「图标 + 文字」的低频动作列表；
    // 「记一笔」不在里面 —— 它是主操作，在右下角 FAB 上（一键进编辑页）
    expect(find.text('记一笔'), findsNothing);
    expect(find.text('开始计时'), findsOneWidget);
    expect(find.text('切换记录本'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    // 一个标签都没有时不出「按标签筛选」
    expect(find.text('按标签筛选'), findsNothing);
  });

  testWidgets('长按进入多选后，标题让位给「已选 N 条」，日期与间隔都消失', (tester) async {
    await _pumpHome(tester, <RecordEntity>[
      _record('a', _dayOffset(0)),
      _record('b', _dayOffset(1)),
    ]);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();

    expect(find.text('已选 1 条'), findsOneWidget);
    expect(find.text(fullDateLabel(DateTime.now())), findsNothing);
    expect(find.text('今天已记录'), findsNothing);
  });
}
