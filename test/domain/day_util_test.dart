import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';

RecordEntity _record({
  required DateTime recordedAt,
  required DateTime createdAt,
  String id = 'r1',
  String content = '1',
  List<String> tags = const <String>[],
  String? title,
}) =>
    RecordEntity(
      bookId: 'default',
      id: id,
      title: title,
      content: content,
      tags: tags,
      recordedAt: recordedAt,
      createdAt: createdAt,
      updatedAt: createdAt,
      deleted: false,
    );

void main() {
  group('日期键与友好标签', () {
    test('dayKey 补零', () {
      expect(dayKey(DateTime(2026, 9, 5)), '2026-09-05');
      expect(dayKey(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('friendlyDayLabel 覆盖 今天/昨天/前天 与更早', () {
      final now = DateTime(2026, 9, 15, 11, 30);
      expect(friendlyDayLabel(DateTime(2026, 9, 15, 1), now: now), '今天');
      expect(friendlyDayLabel(DateTime(2026, 9, 14, 23), now: now), '昨天');
      expect(friendlyDayLabel(DateTime(2026, 9, 13), now: now), '前天');
      expect(friendlyDayLabel(DateTime(2026, 8, 1), now: now), '8月1日');
      expect(friendlyDayLabel(DateTime(2025, 8, 1), now: now), '2025年8月1日');
    });

    test('dayDiff 按日历日算，不受时刻影响', () {
      final a = DateTime(2026, 9, 14, 23, 59);
      final b = DateTime(2026, 9, 15, 0, 1);
      expect(dayDiff(a, b), 1);
    });

    test('lastNDays 从早到晚排列', () {
      final days = lastNDays(3, now: DateTime(2026, 9, 15, 8));
      expect(days.map(dayKey).toList(), <String>[
        '2026-09-13',
        '2026-09-14',
        '2026-09-15',
      ]);
    });

    test('weekdayLabel 中文', () {
      // 2026-09-15 是周二
      expect(weekdayLabel(DateTime(2026, 9, 15)), '周二');
      expect(weekdayLabel(DateTime(2026, 9, 20)), '周日');
    });
  });

  group('补记判定', () {
    test('同一天录入 → 不是补记', () {
      final r = _record(
        recordedAt: DateTime(2026, 9, 15, 9),
        createdAt: DateTime(2026, 9, 15, 22),
      );
      expect(r.isBackfilled, isFalse);
      expect(r.backfillDelayDays, 0);
    });

    test('事后补交 → 是补记，并能算出隔了几天', () {
      final r = _record(
        recordedAt: DateTime(2026, 9, 10, 21),
        createdAt: DateTime(2026, 9, 15, 11),
      );
      expect(r.isBackfilled, isTrue);
      expect(r.backfillDelayDays, 5);
      expect(r.recordedDayKey, '2026-09-10');
    });

    test('归属日是否今天', () {
      final r = _record(
        recordedAt: DateTime(2026, 9, 10, 21),
        createdAt: DateTime(2026, 9, 15, 11),
      );
      expect(r.isRecordedToday(DateTime(2026, 9, 15, 8)), isFalse);
      expect(r.isRecordedToday(DateTime(2026, 9, 10, 8)), isTrue);
    });
  });

  group('键盘输入：年月日时分的合并', () {
    test('五个框齐全且合法 → 合并成一个时间', () {
      expect(
        composeDateTime(
          year: 2026,
          month: 9,
          day: 15,
          hour: 11,
          minute: 4,
        ),
        DateTime(2026, 9, 15, 11, 4),
      );
    });

    test('任一分量缺失 → 不合并（还在输入中）', () {
      expect(
        composeDateTime(year: 2026, month: null, day: 15, hour: 11, minute: 4),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 9, day: 15, hour: null, minute: 4),
        isNull,
      );
    });

    test('越界分量 → 不合并（不会悄悄进位）', () {
      // 2 月 30 日：绝不能被 DateTime 进位成 3 月 2 日
      expect(
        composeDateTime(year: 2026, month: 2, day: 30, hour: 0, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 13, day: 1, hour: 0, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 0, day: 1, hour: 0, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 9, day: 0, hour: 0, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 9, day: 15, hour: 24, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 2026, month: 9, day: 15, hour: 0, minute: 60),
        isNull,
      );
      expect(
        composeDateTime(year: 1899, month: 9, day: 15, hour: 0, minute: 0),
        isNull,
      );
      expect(
        composeDateTime(year: 3000, month: 9, day: 15, hour: 0, minute: 0),
        isNull,
      );
    });

    test('闰年 2 月 29 日合法，平年非法', () {
      expect(
        composeDateTime(year: 2028, month: 2, day: 29, hour: 8, minute: 30),
        DateTime(2028, 2, 29, 8, 30),
      );
      expect(
        composeDateTime(year: 2026, month: 2, day: 29, hour: 8, minute: 30),
        isNull,
      );
    });

    test('lastDayOfMonth 边界', () {
      expect(lastDayOfMonth(2026, 1), 31);
      expect(lastDayOfMonth(2026, 2), 28);
      expect(lastDayOfMonth(2028, 2), 29);
      expect(lastDayOfMonth(2026, 4), 30);
      expect(lastDayOfMonth(2026, 12), 31);
    });

    test('失焦收尾：越界分量被夹到合法范围', () {
      expect(
        clampDateTime(year: 2026, month: 13, day: 32, hour: 25, minute: 61),
        DateTime(2026, 12, 31, 23, 59),
      );
      expect(
        clampDateTime(year: 2026, month: 2, day: 31, hour: 0, minute: 0),
        DateTime(2026, 2, 28),
      );
      expect(
        clampDateTime(year: 2028, month: 2, day: 31, hour: 0, minute: 0),
        DateTime(2028, 2, 29),
      );
      expect(
        clampDateTime(year: 2026, month: 0, day: 0, hour: 0, minute: 0),
        DateTime(2026, 1, 1),
      );
    });
  });

  group('连续记录天数', () {
    test('空列表为 0', () {
      expect(streakDays(const <DateTime>[]), 0);
    });

    test('今天连着记 → 从今天起算', () {
      final now = DateTime(2026, 9, 15, 10);
      final times = <DateTime>[
        DateTime(2026, 9, 15, 9),
        DateTime(2026, 9, 14, 20),
        DateTime(2026, 9, 13, 8),
      ];
      expect(streakDays(times, now: now), 3);
    });

    test('今天还没记，但昨天记了 → 不算断签', () {
      final now = DateTime(2026, 9, 15, 8);
      final times = <DateTime>[
        DateTime(2026, 9, 14, 20),
        DateTime(2026, 9, 13, 8),
      ];
      expect(streakDays(times, now: now), 2);
    });

    test('中间断过 → 只算最近一段', () {
      final now = DateTime(2026, 9, 15, 8);
      final times = <DateTime>[
        DateTime(2026, 9, 15, 7),
        DateTime(2026, 9, 14, 7),
        DateTime(2026, 9, 12, 7), // 13 号缺
        DateTime(2026, 9, 11, 7),
      ];
      expect(streakDays(times, now: now), 2);
    });

    test('同一天多条只算一天', () {
      final now = DateTime(2026, 9, 15, 8);
      final times = <DateTime>[
        DateTime(2026, 9, 15, 7),
        DateTime(2026, 9, 15, 9),
        DateTime(2026, 9, 15, 23),
      ];
      expect(streakDays(times, now: now), 1);
    });

    test('补记过去的日期也能把断掉的连续接回来', () {
      final now = DateTime(2026, 9, 15, 8);
      // 13 号当时忘了记，14 号补记了一条归属 13 号的记录
      final times = <DateTime>[
        DateTime(2026, 9, 15, 7),
        DateTime(2026, 9, 14, 7),
        DateTime(2026, 9, 13, 12), // 补记
        DateTime(2026, 9, 12, 7),
      ];
      expect(streakDays(times, now: now), 4);
    });
  });

  // day_util 里所有「算日期」的函数都改成纯整数（dayNumber）实现了，
  // 因为 DateTime(y,m,d) 的本地构造要问操作系统时区，实测 23 µs/次，
  // 统计一次几万条记录就是几百毫秒。这一组测试是那次改写的安全网：
  // 逐日比对整数路径与 DateTime 路径，确认语义**完全一致**（不是「差不多」）。
  group('整数天数序号与 DateTime 路径等价', () {
    test('dayNumber / civilFromDayNumber 互为逆运算，且与 DateTime 字段一致', () {
      // 覆盖闰年、百年、四百年、月末、跨世纪
      final samples = <DateTime>[
        DateTime(1970, 1, 1),
        DateTime(1969, 12, 31),
        DateTime(1900, 2, 28), // 平年（百年不闰）
        DateTime(2000, 2, 29), // 闰年（四百年闰）
        DateTime(2024, 2, 29),
        DateTime(2026, 9, 15),
        DateTime(2026, 12, 31),
        DateTime(2999, 1, 1),
        DateTime(1900, 1, 1),
      ];
      for (final d in samples) {
        final n = dayNumber(d);
        final back = civilFromDayNumber(n);
        expect(back.year, d.year, reason: '$d 的年');
        expect(back.month, d.month, reason: '$d 的月');
        expect(back.day, d.day, reason: '$d 的日');
      }
    });

    test('dayDiff 与旧实现（两个本地午夜的差值）逐日一致', () {
      // 旧实现：dayStart(b).difference(dayStart(a)).inDays
      int legacy(DateTime a, DateTime b) =>
          dayStart(b).difference(dayStart(a)).inDays;

      // 拿一段跨闰日、跨月末的区间逐日比对，并刻意带上时分秒
      final from = DateTime(2024, 2, 25, 23, 59);
      for (var i = 0; i <= 21; i++) {
        final a = DateTime(from.year, from.month, from.day + i, 23, 59);
        for (var j = 0; j <= 21; j++) {
          final b = DateTime(from.year, from.month, from.day + j, 0, 1);
          expect(dayDiff(a, b), legacy(a, b), reason: '$a → $b');
        }
      }
    });

    test('isSameDay 与 dayKey 比较一致', () {
      final samples = <DateTime>[
        DateTime(2026, 9, 15, 0, 0),
        DateTime(2026, 9, 15, 23, 59),
        DateTime(2026, 9, 16, 0, 0),
        DateTime(2026, 9, 14, 23, 59),
        DateTime(2025, 9, 15),
      ];
      for (final a in samples) {
        for (final b in samples) {
          expect(isSameDay(a, b), dayKey(a) == dayKey(b), reason: '$a vs $b');
        }
      }
    });

    test('分组头标签：整数路径与 DateTime 路径同字', () {
      final now = DateTime(2026, 9, 15, 11, 30);
      final today = dayNumber(now);
      for (var i = -3; i <= 3; i++) {
        final d = DateTime(2026, 9, 15 + i, 8);
        expect(
          groupHeaderLabelOf(dayNumber(d), todayNumber: today),
          // 必须传 `now`：不传的话这条右边会去问真实的「今天」，
          // 而左边用的是写死的 today —— 只有当「真实今天」和它差 0~2 天时
          // 才会暴露（右边少一个「前天 ·」前缀）。这种测试必须自洽，不能靠日期巧合。
          groupHeaderLabel(d, now: now),
        );
      }
      // 跨年、跨月也要带上星期几（星期由整数模运算推出来，最容易算错）
      for (final d in <DateTime>[
        DateTime(2025, 12, 31),
        DateTime(2026, 1, 1),
        DateTime(2026, 3, 1),
        DateTime(2024, 2, 29),
        DateTime(1900, 1, 1),
      ]) {
        expect(
          groupHeaderLabelOf(dayNumber(d), todayNumber: today),
          groupHeaderLabel(d, now: now),
          reason: '$d 的分组头',
        );
      }
    });

    test('星期：整数推出的 weekday 与 DateTime.weekday 一致', () {
      // 用公开 API 间接验证：分组头里的「周二」必须和 DateTime 给的星期对得上
      var d = DateTime(2024, 1, 1);
      for (var i = 0; i < 400; i++) {
        final label = groupHeaderLabelOf(
          dayNumber(d),
          todayNumber: dayNumber(d),
        );
        expect(label, endsWith(weekdayLabel(d)), reason: '$d');
        d = DateTime(d.year, d.month, d.day + 1);
      }
    });

    test('主页标题的日期写法：带年份、带星期、不写「今天」', () {
      // 跑一整年：跨月、跨闰日、跨年都不该有例外
      var d = DateTime(2024, 1, 1);
      for (var i = 0; i < 400; i++) {
        final label = fullDateLabel(d);
        expect(
          label,
          '${d.year}年${d.month}月${d.day}日 ${weekdayLabel(d)}',
          reason: '$d',
        );
        // 标题要的是确定的日期，不是「今天/昨天」这种相对写法
        expect(label.contains('今天'), isFalse);
        d = DateTime(d.year, d.month, d.day + 1);
      }
    });

    test('「距上次记录」的三种写法', () {
      expect(lastRecordGapLabel(null), '还没有记录');
      expect(lastRecordGapLabel(0), '今天已记录');
      expect(lastRecordGapLabel(1), '距上次记录 1 天');
      expect(lastRecordGapLabel(23), '距上次记录 23 天');
      // 记录被填成未来的日期时（用户手滑选了明天），别显示成负数
      expect(lastRecordGapLabel(-1), '今天已记录');
    });
  });
}
