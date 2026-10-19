// 微观基准：day_util 里每个基础函数的单次成本。
//
// 这个文件是一次「性能考古」的产物，留着是为了防止有人再把
// `DateTime(y, m, d)` 放回热路径 —— 它看起来只是「构造个日期」，
// 实际上是**向操作系统问时区**，实测约 23 µs/次，比它内部那几个整数运算
// 贵三个数量级。在每条记录都要过一遍的统计里，这就是几百毫秒的差别。
//
// 用法（默认不跑，见 dart_test.yaml）：flutter test --tags perf
//
// 注意：flutter test 是 JIT，绝对耗时高于 release AOT 真机；
// 看的是「谁比谁贵」的相对关系，不是真机毫秒数。

@Tags(<String>['perf'])
library;

// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/day_util.dart';

void main() {
  const n = 50000;
  final ref = DateTime(2026, 9, 15, 12, 30);

  test('day_util 各基础函数单次成本（N=$n）', () {
    final days = List<DateTime>.generate(
      n,
      (i) => DateTime(2026, 9, 15 - (i % 1500), i % 24, i % 60),
    );

    // 先预热，再计时：只跑一次的话会把首次 JIT 编译时间算进去。
    int timeIt(void Function() body) {
      body();
      final sw = Stopwatch()..start();
      body();
      sw.stop();
      return sw.elapsedMicroseconds;
    }

    void report(String label, int totalUs) {
      print(
        '${label.padRight(30)} ${(totalUs / 1000).toStringAsFixed(1).padLeft(9)} ms'
        '   ${(totalUs / n).toStringAsFixed(3).padLeft(8)} µs/次',
      );
    }

    print('');
    report('dayNumber()（纯整数）', timeIt(() {
      for (final d in days) {
        dayNumber(d);
      }
    }));
    report('civilFromDayNumber()', timeIt(() {
      for (final d in days) {
        civilFromDayNumber(dayNumber(d));
      }
    }));
    report('dayKey()（字符串）', timeIt(() {
      for (final d in days) {
        dayKey(d);
      }
    }));
    report('isSameDay()', timeIt(() {
      for (final d in days) {
        isSameDay(d, ref);
      }
    }));
    report('dayDiff()', timeIt(() {
      for (final d in days) {
        dayDiff(d, ref);
      }
    }));
    report('streakDays() 全量', timeIt(() {
      streakDays(days, now: ref);
    }));
    print('--- 以下是「别放回热路径」的对照组 ---');
    report('dayStart() ⚠️ 本地时间构造', timeIt(() {
      for (final d in days) {
        dayStart(d);
      }
    }));
    report('DateTime(y,m,d) ⚠️ 同上', timeIt(() {
      for (final d in days) {
        DateTime(d.year, d.month, d.day);
      }
    }));
    report('DateTime.now()', timeIt(() {
      for (var i = 0; i < n; i++) {
        DateTime.now();
      }
    }));
    print('');

    // 只保证「整数路径显著快于 DateTime 路径」，不钉具体数值（CI 机器差异大）
    final intUs = timeIt(() {
      for (final d in days) {
        dayNumber(d);
      }
    });
    final dateTimeUs = timeIt(() {
      for (final d in days) {
        dayStart(d);
      }
    });
    expect(
      intUs * 10,
      lessThan(dateTimeUs),
      reason: 'dayNumber 应该比 dayStart 快至少一个数量级',
    );
  });
}
