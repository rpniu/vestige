// 「记录习惯」卡排版的回归测试。
//
// 背景（2026-09-16 重排）：原来 5 个数字块是「固定 104 宽 + Wrap」，
// 手机上只能排成 2+2+1 —— 最后一行孤零零一个，而且右边永远空一截。
// 现在 4 个数字走等宽网格（窄屏 2 列、宽屏 4 列）。
//
// 2026-09-28 改为**窗口口径**：四个数字变成「近 N 天 / 其中补记 / 有记录天数 / 日均条数」，
// 原先的全时段四数字（总记录数/连续记录/活跃天数/补记占比）与「我的」页头卡重复，已移除；
// 底部「近 N 天共 X 条…」那句小字也删了（数字进了格子）。
//
// 这里断言的是**几何**（谁和谁同行、等宽、右边缘对齐），不是截图 ——
// 版式回归用坐标量最直接，也不受字体/平台差异影响。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';

final int _year = DateTime.now().year;

/// 今年年初固定日期的记录（**不用「今天」**，否则跨天跑测试结果会变）。
RecordEntity _record(int i, int month, int day, {int backfillDelayDays = 0}) {
  final recordedAt = DateTime(_year, month, day, 9);
  return RecordEntity(
    id: 'id-$i',
    content: '第 $i 条',
    tags: const <String>[],
    recordedAt: recordedAt,
    createdAt: recordedAt.add(Duration(days: backfillDelayDays)),
    updatedAt: recordedAt,
    deleted: false,
  );
}

/// 3 条普通记录 + 2 条补记（最长隔 31 天）—— 保证补记说明那一段会渲染出来。
List<RecordEntity> _records() => <RecordEntity>[
      _record(1, 1, 5),
      _record(2, 1, 6),
      _record(3, 2, 7),
      _record(4, 3, 8, backfillDelayDays: 31),
      _record(5, 3, 9, backfillDelayDays: 3),
    ];

/// 起一个指定视口的统计页。
///
/// **高度要给够**：统计页 body 是 `ListView`，视口外的卡片根本不会被构建，
/// `find` 自然找不到（会报 `Bad state: No element`）。
/// 「窄屏 / 宽屏」看的是**宽度**，高度只影响「卡片在不在视口里」，
/// 所以给高一点不会改变这些用例想验的几何关系。
/// （2026-09-23 加了「标签分布」卡，洞察卡被往下推，900 高就不够了。）
Future<void> _pumpStats(WidgetTester tester, Size logical) async {
  tester.view.physicalSize = logical * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(_records()),
        ),
      ],
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: const StatsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 数字格子的外框（带底色/圆角的那层 Container）——数字块是私有的，用祖先找最靠里那个。
Rect _tile(WidgetTester tester, String label) => tester.getRect(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (Widget w) => w is Container && w.decoration is BoxDecoration,
            ),
          )
          .first,
    );

/// 四个窗口口径数字格子的标签（首格带窗口天数，随选择器变）。
List<String> _labels(int days) => <String>[
      '近 $days 天',
      '其中补记',
      '有记录天数',
      '日均条数',
    ];

void main() {
  testWidgets('窄屏：2 列 2 行，四块等宽、右边缘与说明框对齐（不留半行空格）', (tester) async {
    await _pumpStats(tester, const Size(360, 2200));

    final labels = _labels(30);
    final first = _tile(tester, labels[0]);
    final second = _tile(tester, labels[1]);
    final third = _tile(tester, labels[2]);
    final fourth = _tile(tester, labels[3]);

    // 成行成列
    expect(first.top, closeTo(second.top, 0.01), reason: '第一行两块要齐平');
    expect(third.top, closeTo(fourth.top, 0.01), reason: '第二行两块要齐平');
    expect(first.top, lessThan(third.top), reason: '应该是两行');
    expect(second.left, closeTo(fourth.left, 0.01), reason: '两列要对齐');

    // 等宽
    for (final r in <Rect>[second, third, fourth]) {
      expect(r.width, closeTo(first.width, 0.01), reason: '四块必须等宽');
      expect(r.height, closeTo(first.height, 0.01), reason: '四块必须等高');
    }
    // 列间距一致
    expect(
      second.left - first.right,
      closeTo(fourth.left - third.right, 0.01),
      reason: '两行之间的列间距要一致',
    );

    // 铺满：左边缘与标题对齐（= 卡片内边距），右边缘与下面那条说明框对齐
    final noteBox = tester.getRect(
      find
          .ancestor(
            of: find.textContaining('补记不算漏记'),
            matching: find.byWidgetPredicate(
              (Widget w) => w is Container && w.decoration is BoxDecoration,
            ),
          )
          .first,
    );
    expect(first.left, closeTo(tester.getTopLeft(find.text('记录习惯')).dx, 0.01));
    expect(fourth.right, closeTo(noteBox.right, 0.01),
        reason: '网格右边缘要铺到卡片内边距处');
  });

  testWidgets('宽屏：4 列一行铺满', (tester) async {
    // 视口要给足高度：统计页新增「记录日历」卡后，「记录习惯」卡位置下移，
    // 800 高的视口它整卡落在屏外（Sliver 惰性构建，find 不到）
    await _pumpStats(tester, const Size(1024, 1500));

    final tiles = <Rect>[
      for (final label in _labels(30)) _tile(tester, label),
    ];

    expect(
      tiles.map((r) => r.top).toSet().length,
      1,
      reason: '宽屏应该排成一行',
    );
    expect(
      tiles.map((r) => r.left.round()).toSet().length,
      4,
      reason: '一行里四块各占一列',
    );
    for (final r in tiles.skip(1)) {
      expect(r.width, closeTo(tiles.first.width, 0.01));
    }
  });

  testWidgets('窗口口径：四个数字都随窗口变；全时段四数字与底部小字都已移除', (tester) async {
    await _pumpStats(tester, const Size(360, 2200));

    // 旧的四个全时段数字：与「我的」页头卡重复，已移除
    for (final label in <String>['总记录数', '连续记录', '活跃天数', '补记占比']) {
      expect(find.text(label), findsNothing,
          reason: '这四个全时段数字与「我的」页重复，不该再出现在统计页');
    }
    // 底部那句小字也删了（数字已进格子）
    expect(find.textContaining('天有记录'), findsNothing);

    // 窗口口径的四个数字在
    for (final label in _labels(30)) {
      expect(find.text(label), findsOneWidget);
    }

    // 补记说明仍保留（它讲的是「补记算什么」，不是总量重复）
    expect(find.textContaining('补记不算漏记'), findsOneWidget);
    expect(find.textContaining('最长一次隔了 31 天才补上'), findsOneWidget);
  });

  testWidgets('窗口选择器：默认 30 天，切到 7 天后四个数字的口径跟着变', (tester) async {
    await _pumpStats(tester, const Size(360, 2200));

    // 三档都在，默认落在 30 —— 与当初硬编码的值一致
    expect(find.widgetWithText(ChoiceChip, '7 天'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '30 天'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '90 天'), findsOneWidget);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 天')).selected,
      isTrue,
    );
    expect(find.text('近 30 天'), findsOneWidget);

    // 切到 7 天：格子标签必须跟着走，否则选择器就是个摆设
    await tester.tap(find.widgetWithText(ChoiceChip, '7 天'));
    await tester.pumpAndSettle();

    expect(find.text('近 7 天'), findsOneWidget);
    expect(find.text('近 30 天'), findsNothing);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '7 天')).selected,
      isTrue,
    );
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 天')).selected,
      isFalse,
    );
  });
}
