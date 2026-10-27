// 统计页「标签分布」卡的渲染回归测试。
//
// 钉住：
// 1. 卡片在，且按次数降序排（次数多的在上面）；
// 2. 一条记录带多个标签时每个标签各有一行；
// 3. 没有带标签的记录时给的是**引导文案**，不是空白卡片；
// 4. 超过上限只列前 N 个，并说明还有几个没列出。
//
// 视口特意开得很高：统计页 body 是 ListView，卡片在视口外就不会被构建，
// `find.text` 自然找不到 —— 不开高一点，这条测试会假失败。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';

final int _year = DateTime.now().year;

RecordEntity _rec(int i, {List<String> tags = const <String>[]}) {
  final at = DateTime(_year, 3, (i % 27) + 1, 9);
  return RecordEntity(
    bookId: 'default',
    id: 'id-$i',
    title: null,
    content: '第 $i 条',
    tags: tags,
    recordedAt: at,
    createdAt: at,
    updatedAt: at,
    deleted: false,
  );
}

Future<void> _pumpStats(WidgetTester tester, List<RecordEntity> records) async {
  tester.view.physicalSize = const Size(412 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => Stream.value(records)),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const StatsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('标签分布卡在，且次数多的排在上面', (tester) async {
    await _pumpStats(tester, <RecordEntity>[
      _rec(1, tags: <String>['c']),
      _rec(2, tags: <String>['c']),
      _rec(3, tags: <String>['a']),
    ]);

    expect(find.text('标签分布'), findsOneWidget);
    expect(find.text('#c'), findsOneWidget);
    expect(find.text('#a'), findsOneWidget);

    final cY = tester.getCenter(find.text('#c')).dy;
    final aY = tester.getCenter(find.text('#a')).dy;
    expect(cY, lessThan(aY), reason: '#c 出现 2 次，该排在 #a 前面');
  });

  testWidgets('一条记录带多个标签：两个标签各有一行', (tester) async {
    await _pumpStats(tester, <RecordEntity>[
      _rec(1, tags: <String>['咖啡', '读书']),
    ]);

    expect(find.text('#咖啡'), findsOneWidget);
    expect(find.text('#读书'), findsOneWidget);
  });

  testWidgets('没有带标签的记录：给引导文案，不是空白', (tester) async {
    await _pumpStats(tester, <RecordEntity>[_rec(1)]);

    expect(find.text('标签分布'), findsOneWidget);
    expect(find.textContaining('还没有带标签的记录'), findsOneWidget);
  });

  testWidgets('标签超过上限：只列前 8 个，并说明还剩几个', (tester) async {
    await _pumpStats(tester, <RecordEntity>[
      for (var i = 0; i < 11; i++) _rec(i, tags: <String>['t$i']),
    ]);

    expect(find.text('还有 3 个标签未列出'), findsOneWidget);
  });
}
