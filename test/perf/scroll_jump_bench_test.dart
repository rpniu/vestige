// 「一键到顶 / 到底」跳转动画的性能基准。
//
// 背景（2026-09-16）：首页原来用 `SliverList`，它的 `performLayout` 是
// `while (endScrollOffset < scrollOffset) advance();` —— 为了知道目标偏移在哪，
// 必须**逐个 layout 中间行**，构建出来再在同一次布局末尾 `collectGarbage` 丢掉。
// 于是跳转成本 = O(总行数)，跟跳多远无关。
//
// 改成「行高提前声明 + SliverVariedExtentList」之后，渲染对象能算术定位到目标 index，
// 跳转成本掉到 O(可见行)，**与总行数无关**。
//
// 实测（360×744 视口，`flutter test` 的 debug/JIT）：
//
//   | 记录数 |   改前：最差单帧 / 动画 CPU 合计   |  改后：最差单帧 / 合计  |
//   | 1000   |       158 ms  /  1212 ms          |         —              |
//   | 3000   |       412 ms  /  2866 ms          |         —              |
//   | 6000   |       769 ms  /  5388 ms          |   50~90 ms / 650~1000 ms |
//
// ⚠️ 时间数字别当结论用：JIT 比 release AOT 慢 5~10 倍，而且本机抖动可达 ±50%
// （同一份代码连跑三次，6000 条那档见过 866 / 926 / 1263 ms）。
// **真正该看的是「首帧构建行数」** —— 它是确定性的：
//   - 改前 = O(总行数)：500 条约 150 行、6000 条约 4500 行；
//   - 改后恒为 20 行左右（≈ 一屏 12 行 + cacheExtent 8 行），与数据量无关。
// 回归断言就钉在这个量上，见 `test/widget/home_fixed_row_test.dart`。
//
// 跑法：`flutter test --run-skipped test/perf/`

@Tags(<String>['perf'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';
import 'package:vestige/presentation/widgets/scroll_jump_button.dart';

List<RecordEntity> _buildRecords(int total, {int perDay = 100}) {
  final now = DateTime.now();
  return <RecordEntity>[
    for (var i = 0; i < total; i++)
      RecordEntity(
        id: 'id-$i',
        content: '第 $i 条',
        tags: const <String>[],
        recordedAt: DateTime(now.year, now.month, now.day - i ~/ perDay, 8, i % 60),
        createdAt: DateTime(now.year, now.month, now.day - i ~/ perDay, 8, i % 60),
        updatedAt: now,
        deleted: false,
      ),
  ];
}

Future<ScrollPosition> _pumpHome(WidgetTester tester, int total) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(_buildRecords(total)),
        ),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<ScrollableState>(find.byType(Scrollable).first).position;
}

/// 从 [from] 跳到 [to]，返回「最差单帧 CPU 耗时 / 合计 CPU 耗时 / 首帧构建的行数」。
Future<({double worst, double sum, int firstFrameBuilds})> _measureJump(
  WidgetTester tester,
  ScrollPosition position, {
  required double from,
  required double to,
}) async {
  // 摆到起点（改成算术定位后，jumpTo 也是 O(1) 的，这一步不再有代价）
  position.jumpTo(from);
  await tester.pump();
  // 热一轮：同样的动画先空跑一遍，否则 JIT 编译时间会污染结果
  position.animateTo(
    to,
    duration: ScrollJumpButton.jumpDuration,
    curve: ScrollJumpButton.jumpCurve,
  );
  await tester.pumpAndSettle();
  position.jumpTo(from);
  await tester.pump();
  await tester.pumpAndSettle();

  RecordCard.debugBuildCount = 0;
  position.animateTo(
    to,
    duration: ScrollJumpButton.jumpDuration,
    curve: ScrollJumpButton.jumpCurve,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  final firstFrameBuilds = RecordCard.debugBuildCount;

  var t = 0;
  var worst = 0.0;
  var sum = 0.0;
  while (t <= ScrollJumpButton.jumpDuration.inMilliseconds + 60) {
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    sw.stop();
    final ms = sw.elapsedMicroseconds / 1000;
    if (ms > worst) worst = ms;
    sum += ms;
    t += 16;
  }
  return (worst: worst, sum: sum, firstFrameBuilds: firstFrameBuilds);
}

void main() {
  for (final total in <int>[500, 2000, 6000]) {
    testWidgets('$total 条：一键到底 / 一键到顶 的每帧耗时', (tester) async {
      final position = await _pumpHome(tester, total);
      final max = position.maxScrollExtent;
      debugPrint('total=$total max=${max.round()} '
          'viewport=${position.viewportDimension}');

      final down = await _measureJump(tester, position, from: 0, to: max);
      debugPrint('  ↓到底 最差帧=${down.worst.toStringAsFixed(1)}ms '
          '合计=${down.sum.toStringAsFixed(1)}ms 首帧构建行数=${down.firstFrameBuilds}');

      final up = await _measureJump(tester, position, from: max, to: 0);
      debugPrint('  ↑到顶 最差帧=${up.worst.toStringAsFixed(1)}ms '
          '合计=${up.sum.toStringAsFixed(1)}ms 首帧构建行数=${up.firstFrameBuilds}');
    });
  }
}
