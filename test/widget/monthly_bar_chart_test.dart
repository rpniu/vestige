// 月度柱状图的回归测试。
//
// 盯着两件事：
// 1. **柱顶数字的纵向余量始终存在** —— 最高那根柱子的数字是画在柱子上方的，
//    量程如果正好等于最大值，数字就会画到图表框外、压住上面那行说明文字。
//    这件事在真机上要碰巧某个月最高才出现，靠肉眼很难回归，所以直接断言公式。
// 2. 各种数据量（全 0 / 只有 1 条 / 三位数 / 空数据）都不要崩，
//    空月份走的是另一条分支（灰色小墩子，不出数字）。

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/widgets/monthly_bar_chart.dart';

List<MonthStat> _data(Map<int, (int, int)> byMonth) => <MonthStat>[
      for (var m = 1; m <= 12; m++)
        MonthStat(
          month: m,
          count: byMonth[m]?.$1 ?? 0,
          backfilled: byMonth[m]?.$2 ?? 0,
        ),
    ];

Future<void> _pump(WidgetTester tester, List<MonthStat> data) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
      home: Scaffold(body: MonthlyBarChart(data: data)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('柱顶数字的纵向余量始终存在，且不会把刻度搞乱', () {
    for (final maxCount in <int>[0, 1, 3, 4, 5, 12, 20, 37, 100, 1000, 99999]) {
      final scale = MonthlyBarChart.scaleFor(maxCount);

      expect(
        scale.maxY,
        greaterThan(maxCount),
        reason: 'maxCount=$maxCount 没有给柱顶数字留余量',
      );
      expect(
        (scale.maxY - maxCount) / scale.maxY,
        greaterThanOrEqualTo(0.12),
        reason: 'maxCount=$maxCount 的余量太小（不足量程的 12%），数字会顶到图表框外',
      );
      // 刻度按 niceMax 出，量程必须 ≥ 它，否则最高那条刻度线画不出来
      expect(scale.niceMax, lessThanOrEqualTo(scale.maxY));
      // 空数据也要有个正经量程（_niceCeil(0) = 4），不能是 0 导致除零
      expect(scale.maxY, greaterThan(0));
    }
  });

  testWidgets('各种数据量都能渲染，不崩', (tester) async {
    final cases = <String, Map<int, (int, int)>>{
      '全空': <int, (int, int)>{},
      '只有一个月有 1 条': <int, (int, int)>{7: (1, 1)},
      '正常分布': <int, (int, int)>{1: (3, 1), 3: (12, 4), 6: (18, 6), 9: (7, 3)},
      '三位数': <int, (int, int)>{5: (240, 0), 8: (128, 40)},
      '一个月顶满、其余为空': <int, (int, int)>{12: (9, 0)},
    };

    for (final entry in cases.entries) {
      await _pump(tester, _data(entry.value));
      expect(
        tester.takeException(),
        isNull,
        reason: '「${entry.key}」这组数据渲染报错了',
      );
      expect(find.byType(BarChart), findsOneWidget, reason: entry.key);
    }
  });
}
