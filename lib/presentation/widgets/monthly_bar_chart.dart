import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

/// 月度柱状图：每个月一根柱，柱子内部按「当天记的 / 事后补记的」分层堆叠，
/// **柱顶带当月条数**。
///
/// 分层是这次重构的视觉重点之一：补记撑起来的月份，柱子顶部会有一段琥珀色，
/// 一眼就能看出「这个月的记录里有多少是后来补的」。
/// 柱顶数字则是把「多少条」从「必须点一下才知道」变成一眼可见。
class MonthlyBarChart extends StatelessWidget {
  const MonthlyBarChart({
    super.key,
    required this.data,
    this.height = 240,
  });

  final List<MonthStat> data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);

    final maxCount = data.fold<int>(0, (p, e) => e.count > p ? e.count : p);
    final scale = scaleFor(maxCount);
    // 柱顶要放一个数字，所以纵向多留一截（见 [_labelRoom]）；**刻度间隔仍按 niceMax 算**，
    // 所以多留这一截不会把 Y 轴刻度搞成怪数字。
    final niceMax = scale.niceMax;
    final maxY = scale.maxY;
    final horizontalStep =
        niceMax <= 4 ? 1.0 : (niceMax / 4).ceilToDouble();
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxY,
          minY: 0,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => scheme.inverseSurface,
              tooltipBorderRadius: BorderRadius.circular(12),
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final index = group.x - 1;
                if (index < 0 || index >= data.length) return null;
                final stat = data[index];
                return BarTooltipItem(
                  '${stat.month}月 · 共 ${stat.count} 条',
                  TextStyle(
                    color: scheme.onInverseSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                  children: <TextSpan>[
                    if (stat.backfilled > 0)
                      TextSpan(
                        text: '\n其中补记 ${stat.backfilled} 条',
                        style: TextStyle(
                          color: tokens.backfill,
                          fontWeight: FontWeight.w500,
                          fontSize: 11,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: horizontalStep,
            getDrawingHorizontalLine: (value) => FlLine(
              // 网格线只是读数的辅助，压淡一档 —— 它比柱子显眼时，图的重点是错的。
              color: scheme.outlineVariant.withValues(alpha: 0.35),
              strokeWidth: 1,
              dashArray: const <int>[4, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 34,
                interval: horizontalStep,
                getTitlesWidget: (value, meta) {
                  // 超过实量程（niceMax）的刻度一律不画：maxY 高出 niceMax 的那一截
                  // 是给柱顶数字留的位置，在那儿标一个刻度会让人误以为量程更大
                  // （35 条的数据出现一个「40」的刻度，读起来很怪）。
                  if (value < 0 || value > niceMax) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      value.toInt().toString(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                      textAlign: TextAlign.right,
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 1 || index > data.length || index != value) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$index',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: data
              .map(
                (stat) => BarChartGroupData(
                  x: stat.month,
                  barsSpace: 0,
                  barRods: <BarChartRodData>[
                    _rod(stat, scheme, tokens, labelStyle),
                  ],
                ),
              )
              .toList(),
        ),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// 柱顶圆角。半径取 8 = 柱宽 16 的一半：这是「顶部看起来还是圆角」的最大值，
  /// 再大柱子就变成胶囊头了。8 也落在卡片那套 12/16/24 圆角刻度的弧线族里。
  static const BorderRadius _rodTop =
      BorderRadius.vertical(top: Radius.circular(8));

  BarChartRodData _rod(
    MonthStat stat,
    ColorScheme scheme,
    VestigeTokens tokens,
    TextStyle? labelStyle,
  ) {
    if (stat.count == 0) {
      // 空月份给一根灰色小墩子，也**不加数字**：什么都记的月份本来就没有数可报，
      // 12 个月都顶一个「0」反而把图压得乱七八糟。
      return BarChartRodData(
        toY: 0,
        width: 16,
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        borderRadius: _rodTop,
      );
    }

    final recorded = stat.count - stat.backfilled;

    return BarChartRodData(
      toY: stat.count.toDouble(),
      width: 16,
      borderRadius: _rodTop,
      color: scheme.primary,
      // 柱顶数字（fl_chart 自己画在柱子正上方，触摸气泡会自动按它的高度让位）。
      label: BarChartRodLabel(
        text: '${stat.count}',
        style: labelStyle,
        offset: const Offset(0, 6),
      ),
      rodStackItems: <BarChartRodStackItem>[
        if (recorded > 0)
          BarChartRodStackItem(0, recorded.toDouble(), scheme.primary),
        if (stat.backfilled > 0)
          BarChartRodStackItem(
            recorded.toDouble(),
            stat.count.toDouble(),
            tokens.backfill,
          ),
      ],
    );
  }

  /// 纵轴量程：`niceMax` 是给刻度用的好看上界，`maxY` 是实际给到 fl_chart 的量程
  /// （在 [niceMax] 之上多留了柱顶数字的位置）。
  ///
  /// 公开成 `@visibleForTesting` 是为了让测试能直接断言「余量始终存在」——
  /// 这个余量一旦没了，最高那根柱子的数字会画到图表框外面压住上面的文字，
  /// 而这件事在真机上要碰巧某个月最高才会出现，靠肉眼很难回归。
  @visibleForTesting
  static ({double niceMax, double maxY}) scaleFor(int maxCount) {
    final niceMax = _niceCeil(maxCount);
    return (niceMax: niceMax, maxY: niceMax + _labelRoom(niceMax));
  }

  /// 柱顶数字需要的纵向余量（数据单位）。
  ///
  /// 取满量程的约 14%（至少 1）：240 高的图里绘图区约 210px，14% ≈ 30px，
  /// 够放一行 11px 的数字 + 6px 间距。比例给得比「刚好够」宽一点，
  /// 是为了让最高那根柱子不贴着上沿 —— 贴着上沿时数字会顶到图表框外。
  static double _labelRoom(double niceMax) {
    final room = (niceMax * 0.14).ceilToDouble();
    return room < 1 ? 1 : room;
  }

  /// 把最大值向上取整到一个**能被 4 整除**的整数。
  ///
  /// 为什么不用 2/5/10 这种「好看的数」（原来就是那样）：`horizontalStep` 是
  /// `ceil(niceMax / 4)`，量程不是 4 的倍数时最后一条刻度会落在量程之外 ——
  /// 35 条数据得到 niceMax=35、步长 9，刻度是 0/9/18/27/36，而 36 已经出了实量程
  /// （那一段是给柱顶数字留的余量），它会被过滤掉，图的上半截于是没有参考线。
  /// 取 4 的倍数之后，四条刻度线正好压在实量程上。
  ///
  /// 20 以内按 4 的倍数分档，而不是直接跳到 20：5 条数据上到 20 的量程时，
  /// 柱子只有四分之一高，看不出「这个月记了 5 条」。
  static double _niceCeil(int maxCount) {
    if (maxCount <= 4) return 4;
    if (maxCount <= 8) return 8;
    if (maxCount <= 12) return 12;
    if (maxCount <= 16) return 16;
    if (maxCount <= 20) return 20;
    return ((maxCount + 3) ~/ 4 * 4).toDouble();
  }
}
