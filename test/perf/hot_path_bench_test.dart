// 热路径基准：把「每次写入都要重算」的那几个纯计算函数在真实数据量下量一遍。
//
// 为什么需要它：`recordsProvider` 是 drift 的响应式流，**任何一次写入都会整表重推**，
// 于是 `RecordStats.from` / 分组 / 近 N 天走势会在同一个 UI isolate 上全部重算。
// 这些函数看起来只是几次遍历，但每条记录里藏了多次字符串拼接（dayKey），
// 数据量一上来就是几十毫秒级的掉帧。改前后都要跑这个文件对照。
//
// 用法（默认不跑，见 dart_test.yaml）：flutter test --tags perf
//
// 注意：flutter test 跑的是 JIT，绝对耗时明显高于 release AOT 真机；
// 这里看的是**同一台机器上的相对变化**（改动前 vs 改动后），不是真机毫秒数。
// 也刻意不做时间断言 —— 时间断言在 CI 上必然抖动，这个文件只负责报数。

@Tags(<String>['perf'])
library;

// ignore_for_file: avoid_print

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

/// 固定的「现在」，避免测试跨越午夜时结果漂移。
final DateTime _now = DateTime(2026, 9, 15, 12, 30);

/// 生成 [n] 条记录：业务日期散布在近 4 年，其中约 10% 是补记。
List<RecordEntity> _genRecords(int n) {
  final rnd = Random(42);
  return List<RecordEntity>.generate(n, (i) {
    final dayOffset = rnd.nextInt(1500);
    final recordedAt = DateTime(
      _now.year,
      _now.month,
      _now.day - dayOffset,
      rnd.nextInt(24),
      rnd.nextInt(60),
    );
    final backfillDays = rnd.nextInt(10) == 0 ? rnd.nextInt(30) + 1 : 0;
    final createdAt = DateTime(
      recordedAt.year,
      recordedAt.month,
      recordedAt.day + backfillDays,
      recordedAt.hour,
      recordedAt.minute,
    );
    return RecordEntity(
      id: 'id-$i',
      content: '记一笔 $i',
      tags: const <String>[],
      recordedAt: recordedAt,
      createdAt: createdAt,
      updatedAt: recordedAt,
      deleted: false,
    );
  });
}

/// 跑 [rounds] 次取最小值：最大值会被首次运行的 JIT 预热污染，最小值最接近稳态。
int _bestUs(int rounds, void Function() body) {
  var best = 1 << 62;
  for (var i = 0; i < rounds; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
  }
  return best;
}

String _fmt(int microseconds) => '${(microseconds / 1000).toStringAsFixed(1)} ms';

void main() {
  test('热路径耗时基准（按数据量）', () {
    const sizes = <int>[1000, 5000, 20000, 50000];

    print('');
    print('每行 = 一次完整重算（写入一条记录后，UI isolate 上要跑的全部计算）');
    print(
      '${'N'.padLeft(7)} | ${'stats'.padLeft(10)} | ${'分组'.padLeft(10)} | '
      '${'近30天'.padLeft(10)} | ${'合计'.padLeft(10)}',
    );
    print('-' * 66);

    for (final n in sizes) {
      final records = _genRecords(n);

      // 预热一次，把 drift 数据类首次访问的开销排除掉
      RecordStats.from(records, now: _now);
      groupRecordsByDay(records);
      buildDailySeries(records, 30, now: _now);

      final statsUs = _bestUs(
        3,
        () => RecordStats.from(records, now: _now),
      );
      final groupUs = _bestUs(
        3,
        () => groupRecordsByDay(records),
      );
      final seriesUs = _bestUs(
        3,
        () => buildDailySeries(records, 30, now: _now),
      );

      print(
        '${n.toString().padLeft(7)} | ${_fmt(statsUs).padLeft(10)} | '
        '${_fmt(groupUs).padLeft(10)} | ${_fmt(seriesUs).padLeft(10)} | '
        '${_fmt(statsUs + groupUs + seriesUs).padLeft(10)}',
      );
    }

    print('');
    print('参考：60fps 的预算 = 16.7 ms/帧，超过就是在掉帧。');
    print('');

    // 只做最基本的存在性断言，保证产出的数字不是「什么都没算」得来的。
    final records = _genRecords(1000);
    final stats = RecordStats.from(records, now: _now);
    expect(stats.totalCount, 1000);
    expect(stats.backfilledCount, greaterThan(0));
  });
}
