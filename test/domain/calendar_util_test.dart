// 月历网格构建的纯函数测试。
//
// 钉住：周一开头的占位规则（1 号是周几决定前面几个空格）、
// 行数按实际天数、统计按日号落到正确的格子、今天 / 未来的判定。
// 2026 年不是闰年，2 月 28 天；2026-09-01 是周二，2026-06-01 是周一，
// 2026-02-01 是周日（这几个星期断言同时覆盖了三种占位宽度）。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/calendar_util.dart';

void main() {
  group('buildMonthGrid', () {
    test('1 号是周二：前面 1 个空格，共 1 + 30 格（2026 年 9 月）', () {
      final cells = buildMonthGrid(2026, 9, const <int, CalendarDayStat>{});
      expect(cells.length, 31);
      expect(cells.first, isA<CalendarBlankCell>());
      expect((cells[1] as CalendarDayCell).day, 1);
      expect((cells[30] as CalendarDayCell).day, 30);
    });

    test('1 号是周一：没有空格（2026 年 6 月）', () {
      final cells = buildMonthGrid(2026, 6, const <int, CalendarDayStat>{});
      expect(cells.length, 30);
      expect(cells.first, isA<CalendarDayCell>());
      expect((cells.first as CalendarDayCell).day, 1);
    });

    test('1 号是周日：前面 6 个空格（2026 年 2 月，平年 28 天）', () {
      final cells = buildMonthGrid(2026, 2, const <int, CalendarDayStat>{});
      expect(cells.length, 6 + 28);
      expect(cells.whereType<CalendarBlankCell>().length, 6);
      expect((cells[6] as CalendarDayCell).day, 1);
    });

    test('统计按日号落到正确格子；没有记录的日子是空统计', () {
      final cells = buildMonthGrid(
        2026,
        9,
        const <int, CalendarDayStat>{
          5: CalendarDayStat(count: 3, backfilled: 1),
        },
      );
      final day5 = cells.whereType<CalendarDayCell>().firstWhere(
            (c) => c.day == 5,
          );
      expect(day5.stat.count, 3);
      expect(day5.stat.hasBackfill, isTrue);
      final day6 = cells.whereType<CalendarDayCell>().firstWhere(
            (c) => c.day == 6,
          );
      expect(day6.stat.count, 0);
      expect(day6.stat.hasBackfill, isFalse);
    });

    test('当月：今天是今天，今天之后是未来；未来月份整月是未来', () {
      final now = DateTime(2026, 9, 15, 12, 0);
      final cells = buildMonthGrid(
        2026,
        9,
        const <int, CalendarDayStat>{},
        now: now,
      );
      final byDay = <int, CalendarDayCell>{
        for (final c in cells.whereType<CalendarDayCell>()) c.day: c,
      };
      expect(byDay[14]!.isFuture, isFalse);
      expect(byDay[14]!.isToday, isFalse);
      expect(byDay[15]!.isToday, isTrue);
      expect(byDay[15]!.isFuture, isFalse);
      expect(byDay[16]!.isFuture, isTrue);

      final futureMonth = buildMonthGrid(
        2026,
        10,
        const <int, CalendarDayStat>{},
        now: now,
      );
      expect(
        futureMonth.whereType<CalendarDayCell>().every((c) => c.isFuture),
        isTrue,
      );
      // 未来月份的「1 号」也不许被标成今天
      expect(
        futureMonth.whereType<CalendarDayCell>().any((c) => c.isToday),
        isFalse,
      );
    });
  });
}
