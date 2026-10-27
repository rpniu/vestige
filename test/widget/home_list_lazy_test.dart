// 首页列表的惰性构建回归测试。
//
// 背景：首页原来是「一个分组 = 一个 SliverList item，内部套 Column 铺完该天所有卡片」。
// 这个 App 的核心操作是长按 FAB 立刻记一条，一天堆出几百条很常见，
// 于是滚到那天会在同一帧里构建几百张卡片 —— 掉帧感很明显。
//
// 拍平成「分组头 + 卡片」的单条行列表后，屏幕外的卡片不再构建。
// 这里就钉住这个性质：**构建出来的卡片数必须远小于数据条数**。
// 如果有人改回 Column 铺开，这个测试会立刻红。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _record(int i, DateTime day) => RecordEntity(
      bookId: 'default',
      id: 'id-$i',
      content: '第 $i 条',
      tags: const <String>[],
      recordedAt: DateTime(day.year, day.month, day.day, 8, i % 60),
      createdAt: DateTime(day.year, day.month, day.day, 8, i % 60),
      updatedAt: day,
      deleted: false,
    );

/// 相对「今天」的第 [offset] 天（0 = 今天）。
/// 不写死日期，否则测试换个日子跑就会挂。
DateTime _dayOffset(int offset) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - offset);
}

Future<void> _pumpHome(WidgetTester tester, List<RecordEntity> records) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => Stream<List<RecordEntity>>.value(records)),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('一天 300 条：只构建屏幕内那几张卡片，不是全部 300 张', (tester) async {
    final day = _dayOffset(0);
    final records = <RecordEntity>[
      for (var i = 0; i < 300; i++) _record(i, day),
    ];

    await _pumpHome(tester, records);

    final built = find.byType(RecordCard, skipOffstage: false).evaluate().length;
    expect(built, greaterThan(0), reason: '至少要构建出屏幕内的卡片');
    // 实测：800×600 的测试视口下只建 9 张（改回 Column 铺开则会建满 300 张）。
    // 留一点余量给 viewport / cacheExtent 的差异，但门槛必须远小于 300，
    // 否则这个测试就抓不到「又变回一次性铺开」的退化。
    expect(
      built,
      lessThan(40),
      reason: '实测应为个位数（约 9 张）；若接近 300，说明又变回一次性铺开了',
    );
  });

  testWidgets('多天数据：分组头与卡片都在，且按日期倒序', (tester) async {
    final records = <RecordEntity>[
      _record(1, _dayOffset(2)),
      _record(2, _dayOffset(0)),
      _record(3, _dayOffset(1)),
    ];

    await _pumpHome(tester, records);

    // 分组头是一整行（`今天 · 9月15日 周二`），所以用包含匹配。
    // **必须限定在列表里**：AppBar 标题第二行也跟着日期走（今天已记录 / 距上次记录 N 天），
    // 全局搜「今天」会把它一起捞进来。
    Finder headerContaining(String text) => find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.textContaining(text),
        );

    final todayHeader = headerContaining('今天');
    final yesterdayHeader = headerContaining('昨天');
    final beforeHeader = headerContaining('前天');
    expect(todayHeader, findsOneWidget);
    expect(yesterdayHeader, findsOneWidget);
    expect(beforeHeader, findsOneWidget);
    expect(find.byType(RecordCard), findsNWidgets(3));

    // 最新的那天在最上面
    final todayY = tester.getTopLeft(todayHeader).dy;
    final yesterdayY = tester.getTopLeft(yesterdayHeader).dy;
    final beforeY = tester.getTopLeft(beforeHeader).dy;
    expect(todayY, lessThan(yesterdayY));
    expect(yesterdayY, lessThan(beforeY));
  });

  testWidgets('空数据：显示空状态而不是崩', (tester) async {
    await _pumpHome(tester, const <RecordEntity>[]);
    expect(find.text('还没有任何记录'), findsOneWidget);
    expect(find.byType(RecordCard), findsNothing);
  });
}
