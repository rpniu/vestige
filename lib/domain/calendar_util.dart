/// 月历网格构建（纯 Dart，零依赖，可单测）—— 统计页「记录日历」卡的布局来源。
library;

import 'package:vestige/domain/day_util.dart';

/// 某一天的统计：条数 + 其中补记条数。
class CalendarDayStat {
  const CalendarDayStat({this.count = 0, this.backfilled = 0});

  final int count;
  final int backfilled;

  bool get hasBackfill => backfilled > 0;
}

/// 月历网格里的一格。
sealed class CalendarCell {
  const CalendarCell();
}

/// 月首前面的占位空格（本月 1 号不是周一就有）。
final class CalendarBlankCell extends CalendarCell {
  const CalendarBlankCell();
}

/// 一个真实的日子。
final class CalendarDayCell extends CalendarCell {
  const CalendarDayCell({
    required this.day,
    required this.stat,
    required this.isToday,
    required this.isFuture,
  });

  /// 日号（1–31）。
  final int day;

  final CalendarDayStat stat;

  /// 今天（只有展示当月才可能为 true）。
  final bool isToday;

  /// 还没到的那一天（展示当月里今天之后的日子；未来的月份整月都是）。
  /// 未来格不可点、不着色 —— 那还不是「没记」，是「还没到」。
  final bool isFuture;
}

/// 构建 [year]-[month] 的月历网格：**周一开头**，月首前的空格用
/// [CalendarBlankCell] 占位。行数按需 4~6 行（不强行凑满 6 行），
/// 网格末尾不留空格 —— 末尾空格没有信息量，还让最后一行显得残。
///
/// [stats] 以**日号**为键（只有展示月份的数据，由调用方聚合好）。
/// [now] 可注入，方便单测与预览。
List<CalendarCell> buildMonthGrid(
  int year,
  int month,
  Map<int, CalendarDayStat> stats, {
  DateTime? now,
}) {
  // DateTime 构造在这里一个月只发生两次（1 号 + 月末），不是热路径
  final firstWeekday = DateTime(year, month, 1).weekday; // 周一=1 … 周日=7
  final daysInMonth = lastDayOfMonth(year, month);
  final today = now ?? DateTime.now();
  final isCurrentMonth = today.year == year && today.month == month;
  final monthIsFuture =
      year > today.year || (year == today.year && month > today.month);

  return <CalendarCell>[
    for (var i = 0; i < firstWeekday - 1; i++) const CalendarBlankCell(),
    for (var d = 1; d <= daysInMonth; d++)
      CalendarDayCell(
        day: d,
        stat: stats[d] ?? const CalendarDayStat(),
        isToday: isCurrentMonth && today.day == d,
        isFuture: monthIsFuture || (isCurrentMonth && d > today.day),
      ),
  ];
}
