// 首页固定行高 + 算术定位跳转的回归测试。
//
// 背景：首页原来用 `SliverList`，它的 `performLayout` 是
// `while (endScrollOffset < scrollOffset) advance();` —— 必须**逐个 layout 中间行**
// 才知道目标偏移在哪，于是「一线到底」会把中间几千行全部构建 + 布局一遍再丢掉。
// 实测 6000 条记录时一个 320ms 的跳转动画烧掉 5.4 秒 CPU，前几帧每帧卡 700ms。
//
// 改成「行高提前声明」（`SliverVariedExtentList` + `VestigeRowMetrics`）后，
// 渲染对象能算术定位到目标 index，跳转成本与总行数无关。
//
// 这个文件钉住三件事：
// 1. 跳到底的第一帧**不再**把中间行构建一遍（否则就是又退回 O(总行数)）；
// 2. 卡片实际高度 == 声明的行高（声明和渲染必须同源，否则会出现 1px 缝/溢出）；
// 3. 最坏内容（标题 + 长正文 + 一堆标签 + 补记）在各种系统字号下都不溢出。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';
import 'package:vestige/presentation/widgets/row_metrics.dart';

RecordEntity _record(
  int i,
  DateTime day, {
  String? title,
  String? content,
  List<String> tags = const <String>[],
  DateTime? createdAt,
}) {
  final at = DateTime(day.year, day.month, day.day, 8, i % 60);
  return RecordEntity(
    bookId: 'default',
    id: 'id-$i',
    title: title,
    content: content ?? '第 $i 条',
    tags: tags,
    recordedAt: at,
    createdAt: createdAt ?? at,
    updatedAt: day,
    deleted: false,
  );
}

/// 相对「今天」的第 [offset] 天（0 = 今天）。不写死日期，换天跑也不会挂。
DateTime _dayOffset(int offset) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - offset);
}

Future<void> _pumpHome(
  WidgetTester tester,
  List<RecordEntity> records, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(records),
        ),
      ],
      child: MaterialApp(
        // 用真实主题跑：行高常量是按这套排版算出来的，脱离它就是另一回事了
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: const HomeScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  testWidgets('跳到底：第一帧只构建可见的行，不再把中间 2000 行走一遍', (tester) async {
    // 2000 条 / 20 天：行高约 90px，总长约 18 万 px。
    // 旧的 SliverList 在这一帧要构建约 15% × 2000 ≈ 300 行（easeOutCubic 首帧推进 14.3%）。
    final records = <RecordEntity>[
      for (var i = 0; i < 2000; i++) _record(i, _dayOffset(i ~/ 100)),
    ];
    await _pumpHome(tester, records);

    // 往上滑一下让按钮翻成「到底」。
    // 滑两次是有意的：`tester.drag` 把整段位移作为**一个**滚动事件发出，
    // 而按钮要「上一次的偏移」才知道方向 —— 第一次只记住位置，第二次才翻向。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.vertical_align_bottom_rounded), findsOneWidget);

    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(100000));

    RecordCard.debugBuildCount = 0;
    await tester.tap(find.byKey(const ValueKey('to_bottom_button')));
    await tester.pump(); // 动画第 0 帧：偏移还没动
    await tester.pump(const Duration(milliseconds: 16)); // 第一个真正推进的帧

    final firstFrameBuilds = RecordCard.debugBuildCount;
    await tester.pumpAndSettle();

    expect(
      firstFrameBuilds,
      lessThan(60),
      reason: '第一帧构建量应该只有一屏的量（约 10 行）。'
          '若接近 300+，说明又退回了「逐行走完中间所有行」的 SliverList 行为',
    );
    // 跳转本身仍然要真的落到末尾
    expect(_position(tester).pixels, _position(tester).maxScrollExtent);
  });

  testWidgets('卡片实际高度 == 声明的行高（紧凑档 / 完整档各验一次）', (tester) async {
    final records = <RecordEntity>[
      _record(1, _dayOffset(0)), // 紧凑档：没标题没元信息
      _record(2, _dayOffset(0), title: '有标题', tags: const <String>['a', 'b']),
      // 紧凑档 + 正文占满 2 行：最紧的那种（58 贴 60 的预算）
      _record(3, _dayOffset(0), content: '很长很长的正文' * 8),
    ];
    await _pumpHome(tester, records);

    final ctx = tester.element(find.byType(RecordCard).first);
    final cases = <(String, bool)>[('id-1', true), ('id-2', false), ('id-3', true)];
    for (final (id, dense) in cases) {
      final finder = find.byWidgetPredicate(
        (Widget w) => w is RecordCard && w.record.id == id,
      );
      expect(finder, findsOneWidget, reason: '$id 应该渲染出来');
      expect(
        tester.getSize(finder).height,
        closeTo(VestigeRowMetrics.cardHeight(ctx, dense: dense), 0.01),
        reason: '$id 的卡片高度与声明的行高（dense=$dense）不一致',
      );
    }

    // 「行高 = 卡片高 + 间隙」这条关系不能写反
    expect(
      VestigeRowMetrics.cardExtent(ctx, dense: true),
      closeTo(VestigeRowMetrics.cardHeight(ctx, dense: true) + VestigeRowMetrics.gap, 0.01),
    );
    // 分档必须真的矮下来，否则这套分档就是白写的
    expect(
      VestigeRowMetrics.cardHeight(ctx, dense: true),
      lessThan(VestigeRowMetrics.cardHeight(ctx, dense: false)),
    );
  });

  testWidgets('最坏内容 + 各种系统字号：都不溢出', (tester) async {
    final records = <RecordEntity>[
      // 完整档最坏组合：标题 + 长正文 + 一堆标签 + 补记（元信息行最长）
      _record(
        1,
        _dayOffset(0),
        title: '标题也可以很长很长很长很长很长很长',
        content: '正文很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长',
        tags: const <String>['标签一', '标签二', '标签三', '标签四', '标签五'],
        createdAt: _dayOffset(4),
      ),
      // 紧凑档最坏组合：没标题没标签，正文顶满 2 行（38 那档的上界）
      _record(2, _dayOffset(0), content: '没有标题的正文很长' * 12),
      // 最矮的一档
      _record(3, _dayOffset(0)),
    ];

    for (final scale in <double>[1.0, 1.15, 1.3, 1.6]) {
      await _pumpHome(tester, records, textScale: scale);
      expect(
        tester.takeException(),
        isNull,
        reason: '字号 $scale 下卡片内容顶破了声明的行高',
      );

      final ctx = tester.element(find.byType(RecordCard).first);
      final cases = <(String, bool)>[('id-1', false), ('id-2', true), ('id-3', true)];
      for (final (id, dense) in cases) {
        final finder = find.byWidgetPredicate(
          (Widget w) => w is RecordCard && w.record.id == id,
        );
        expect(
          tester.getSize(finder).height,
          closeTo(VestigeRowMetrics.cardHeight(ctx, dense: dense), 0.01),
          reason: '字号 $scale 下 $id 的行高对不上',
        );
      }
    }
  });
}
