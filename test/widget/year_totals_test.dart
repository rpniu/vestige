// 「每年的总记录数量」的回归测试。
//
// 新增这个数字时它被放在了两个地方，各解决一个不同的问题：
// 1. 「月度分布」柱图下面的图注 → 不点开任何东西就知道**当前这一年**一共多少条。
//    柱顶数字要一根根看，合计一眼就能看到。
// 2. 年份弹层每行右侧 → 年份列表是唯一能**横着比较各年份**的地方，
//    「哪年记得多」只有在这儿才看得出来。
//
// 顺带钉住一个被这次改动带出来的边界：选中的年份如果记录被删光了，
// 药丸、柱图、图注必须**一起**退回最新的一年 —— 以前药丸会退回、
// 柱图还按旧年份画（药丸写 2026、图里全是 0），有了图注那个数字之后
// 这种不一致就更容易被看出来。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';
import 'package:vestige/presentation/widgets/monthly_bar_chart.dart';

/// 用**今年年初**的日期，避免跨天/跨年跑测试时结果变化。
final int _year = DateTime.now().year;

RecordEntity _record(int i, int year, int month, int day) {
  final at = DateTime(year, month, day, 9);
  return RecordEntity(
    id: 'id-$i',
    content: '第 $i 条',
    tags: const <String>[],
    recordedAt: at,
    createdAt: at,
    updatedAt: at,
    deleted: false,
  );
}

/// 今年 3 条 + 去年 2 条 —— 两年各自的数不一样，才能验出「每行算各自的」。
List<RecordEntity> _records() => <RecordEntity>[
      _record(1, _year, 1, 1),
      _record(2, _year, 1, 2),
      _record(3, _year, 1, 3),
      _record(4, _year - 1, 5, 5),
      _record(5, _year - 1, 6, 6),
    ];

/// 当前柱图拿到的那份月度数据（柱顶数字是画在 canvas 上的，抓不到 `Text`，
/// 只能从组件属性上读）。
List<MonthStat> _chartData(WidgetTester tester) =>
    tester.widget<MonthlyBarChart>(find.byType(MonthlyBarChart)).data;

int _chartTotal(WidgetTester tester) =>
    _chartData(tester).fold<int>(0, (p, e) => p + e.count);

Future<void> _pumpStats(WidgetTester tester, Stream<List<RecordEntity>> source) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => source),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const StatsScreen(),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('$_year 年'));
  await tester.pumpAndSettle();
  expect(find.text('选择年份'), findsOneWidget, reason: '弹层没打开');
}

void main() {
  testWidgets('柱图下面的合计给出当年总量；弹层里每行标出各自的年份总量', (tester) async {
    await _pumpStats(tester, Stream<List<RecordEntity>>.value(_records()));
    await tester.pumpAndSettle();

    // 1. 不打开任何东西：当前年份的合计就在柱图下面
    expect(
      find.textContaining('该年共 3 条'),
      findsOneWidget,
      reason: '统计页一进来就该看到该年的总条数',
    );

    // 2. 弹层里每一年一行、各自算各自的
    await _openSheet(tester);
    expect(find.text('3 条'), findsOneWidget, reason: '今年那行要标 3 条');
    expect(find.text('2 条'), findsOneWidget, reason: '去年那行要标 2 条');
    expect(find.text('共 2 年'), findsOneWidget);

    // 弹层里最该方便比较的就是这一列数字，所以它必须**成列**：
    // 勾选图标只出现在选中的那行，它的位置如果不给别的行预留，
    // 选中行的「N 条」就会被往左挤开，一眼看去还以为它比别的行多几位。
    expect(
      tester.getRect(find.text('3 条')).right,
      closeTo(tester.getRect(find.text('2 条')).right, 0.01),
      reason: '选中行（带勾选图标）和非选中行的条数要右对齐成一列',
    );

    // 3. 切到去年：图注和柱图一起换成去年的数
    await tester.tap(find.text('${_year - 1} 年'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('该年共 2 条'),
      findsOneWidget,
      reason: '换了年份，合计要跟着换',
    );
    expect(_chartTotal(tester), 2, reason: '图注和柱图必须是同一年的数据');
    expect(find.text('${_year - 1} 年'), findsOneWidget, reason: '药丸上是去年');
  });

  testWidgets('今年还一条都没有：图注直说没有记录，弹层里那行是 0 条', (tester) async {
    await _pumpStats(
      tester,
      Stream<List<RecordEntity>>.value(
        <RecordEntity>[
          for (final r in _records())
            if (r.recordedAt.year == _year - 1) r,
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('该年还没有记录'), findsOneWidget);
    expect(find.textContaining('该年共'), findsNothing);

    await _openSheet(tester);
    expect(find.text('0 条'), findsOneWidget, reason: '今年这一行也照实报 0，不留空');
    expect(find.text('2 条'), findsOneWidget);
  });

  testWidgets('选中的年份被删空：药丸、柱图、当年合计一起退回最新的一年', (tester) async {
    final controller = StreamController<List<RecordEntity>>();
    addTearDown(controller.close);

    await _pumpStats(tester, controller.stream);
    controller.add(_records());
    await tester.pumpAndSettle();

    // 先切到去年
    await _openSheet(tester);
    await tester.tap(find.text('${_year - 1} 年'));
    await tester.pumpAndSettle();
    expect(_chartTotal(tester), 2);

    // 把去年的记录全删掉 —— 此时 selectedYear（去年）已经不是「有记录的年份」了
    controller.add(
      <RecordEntity>[
        for (final r in _records())
          if (r.recordedAt.year == _year) r,
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('$_year 年'), findsOneWidget, reason: '药丸要退回最新的一年');
    expect(
      find.textContaining('该年共 3 条'),
      findsOneWidget,
      reason: '合计不能还停在已经被删空的那一年',
    );
    expect(_chartTotal(tester), 3, reason: '柱图要跟药丸画同一年，不能还是 0');
  });
}
