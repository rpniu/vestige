// 「速记」独立入口的回归测试。
//
// 背景（2026-09-28）：速记原来是「长按右下角 FAB」，但那个实现在安卓端完全失效 ——
// `FloatingActionButton` 内部的 InkWell 自带长按识别器，与外包的
// `GestureDetector.onLongPress` 在手势竞技场里冲突，外层回调永远不触发。
// 桌面端因为 tooltip 还走一条路，所以「看着像是能用」，掩盖了安卓端的问题。
//
// 现在改成右下角按钮列里的**独立按钮**（白底 + 主色闪电图标），
// 与「到顶/到底」「记一笔」竖着叠成一列。
//
// 这里钉住四件事：
// 1. 速记按钮在首页存在，位置在 FAB 上方、两者不重叠；
// 2. 点击会真的插入一条记录（内容 = 「速记」，业务日期 = 今天）；
// 3. 插入后弹撤销提示（带「撤销」动作），点它能退掉；
// 4. 速记**不再**挂在 FAB 的长按上 —— 长按 FAB 什么都不该发生。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();

    // 一律用内存库：`VestigeDatabase()` 的缺省构造会打开
    // `<文档目录>/vestige/vestige.sqlite`，测试里绝不能碰用户的真实数据。
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  /// 起首页。这里**不 override `recordsProvider`**：速记会写真实内存库，
  /// 列表要跟着流实时更新，override 成常量流反而看不出「真的插进去了」。
  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412 * 3, 892 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          theme: buildVestigeTheme(
            AppThemeVariant.defaultBlue,
            Brightness.light,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 收尾：把 drift 流的销毁定时器走完。
  ///
  /// 必须写在**测试体末尾**，不能放 `addTearDown` —— 框架的
  /// `_verifyInvariants`（检查有没有挂着的定时器）在 `_runTestBody` 末尾就跑，
  /// 早于 tearDown 回调。理由与 `undo_test.dart` 同（那里有完整说明）。
  Future<void> drainStreamTeardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  /// dock 段/FAB 的标称边长（56），用于等尺寸断言。
  const double _buttonSideForTest = 56;

  /// 速记按钮：白底 Material 包着的闪电图标。
  Finder quickNoteButton() => find.byIcon(Icons.bolt_rounded);

  testWidgets('首页有速记按钮，且排在「记一笔」FAB 上方、两者不重叠', (tester) async {
    await pumpHome(tester);

    expect(quickNoteButton(), findsOneWidget);
    // 与「记一笔」的 + 图标是两个不同的按钮
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);

    final quickNote = tester.getRect(quickNoteButton());
    // 量 FAB 的外框 SizedBox（FAB 自身 render box 受主题 tapTargetSize 影响）
    final fab = tester.getRect(find.byKey(const ValueKey('fab_button')));
    expect(
      quickNote.bottom,
      lessThan(fab.top),
      reason: '速记按钮应排在 FAB 上方，不能压在一起',
    );

    await drainStreamTeardown(tester);
  });

  testWidgets('dock 段顺序：自下而上是「记一笔 → 速记 → 计时」', (tester) async {
    await pumpHome(tester);

    // 量尺寸必须找按钮整体（Semantics 上的 key），byIcon 只会量到 24px 图标
    final quickNote = tester.getRect(
      find.byKey(const ValueKey('quick_note_button')),
    );
    final timer = tester.getRect(find.byKey(const ValueKey('timer_button')));

    // y 轴向下：越靠屏幕下方 bottom 越大 —— FAB 在最下面，bottom 应最大；
    // 计时段在速记之上。
    expect(
      timer.bottom,
      lessThan(quickNote.bottom),
      reason: '速记是 dock 最下段，应在计时段下方',
    );
    // 等宽等高（同一套规格常量）
    expect(timer.width, closeTo(_buttonSideForTest, 0.01));
    expect(quickNote.height, closeTo(_buttonSideForTest, 0.01));
    expect(timer.height, closeTo(_buttonSideForTest, 0.01));

    await drainStreamTeardown(tester);
  });

  testWidgets('点速记：直接插入一条今天的记录，内容为「速记」', (tester) async {
    await pumpHome(tester);
    expect(await repo.getAllActiveRecordsSync(), isEmpty);

    await tester.tap(quickNoteButton());
    await tester.pumpAndSettle();

    final saved = await repo.getAllActiveRecordsSync();
    expect(saved, hasLength(1));
    expect(saved.single.content, '速记');
    // 业务日期是今天 —— 速记落今天，不算补记
    expect(saved.single.isRecordedToday(), isTrue);

    await drainStreamTeardown(tester);
  });

  testWidgets('速记后弹出带「撤销」的提示', (tester) async {
    await pumpHome(tester);

    await tester.tap(quickNoteButton());
    await tester.pumpAndSettle();

    expect(find.text('已速记一条（今天）'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);

    await drainStreamTeardown(tester);
  });

  testWidgets('速记提示上的「撤销」能把刚记的那条退掉', (tester) async {
    await pumpHome(tester);

    await tester.tap(quickNoteButton());
    await tester.pumpAndSettle();
    expect(await repo.getAllActiveRecordsSync(), hasLength(1));

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(
      await repo.getAllActiveRecordsSync(),
      isEmpty,
      reason: '撤销应把刚速记的那条软删掉',
    );

    await drainStreamTeardown(tester);
  });

  testWidgets('长按 FAB 不再速记（旧的 GestureDetector 方案已移除）', (tester) async {
    await pumpHome(tester);

    await tester.longPress(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 长按 FAB 一个记录都不该产生
    expect(await repo.getAllActiveRecordsSync(), isEmpty);
    expect(find.text('已速记一条（今天）'), findsNothing);

    await drainStreamTeardown(tester);
  });
}
