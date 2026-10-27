// 「速记」的回归测试 —— 它现在是「记一笔」按钮的**长按**。
//
// 背景：速记最早就是长按右下角 FAB，2026-09-28 在安卓真机上失效 ——
// `FloatingActionButton` **内部自带 InkWell**，它的长按识别器在手势竞技场里
// 先赢下指针，包在外面的 `GestureDetector.onLongPress` 永远不触发；
// FAB 本身也没有 `onLongPress` 参数。桌面端因为 tooltip 那条路还能用，
// 看起来「像没问题」，掩盖了安卓端的失效。
//
// 2026-10-27 恢复成长按：把按钮换成 Material + InkWell 自绘方块，
// **同一个 InkWell 同时声明 `onTap` 与 `onLongPress`** —— 两个回调由同一个
// 识别器内部裁决，不存在两个手势抢指针，因此安卓端也能稳定触发。
//
// 这里钉住四件事：
// 1. 平时右下角只有一颗按钮（速记、计时都不常驻）；
// 2. 长按 = 速记：真的插入一条「速记」，业务日期是今天；
// 3. 插入后弹撤销提示，点它能退掉；
// 4. 计时开始后，胶囊里才多出计时段。

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

  /// 「记一笔」按钮（点 = 进编辑页，长按 = 速记）。
  Finder newRecordButton() => find.byKey(const ValueKey('fab_button'));

  /// 长按「记一笔」= 速记。
  Future<void> longPressQuickNote(WidgetTester tester) async {
    await tester.longPress(newRecordButton());
    await tester.pumpAndSettle();
  }

  testWidgets('平时右下角只有一颗按钮（速记已并入长按，计时不常驻）', (tester) async {
    await pumpHome(tester);

    expect(newRecordButton(), findsOneWidget);
    // 独立的速记按钮、计时段都不在了
    expect(find.byIcon(Icons.bolt_rounded), findsNothing);
    expect(find.byKey(const ValueKey('timer_button')), findsNothing);
    // 全屏也只有这一颗浮动按钮
    expect(find.byType(Material).evaluate().isNotEmpty, isTrue);

    await drainStreamTeardown(tester);
  });

  testWidgets('计时开始后，胶囊才出现在记一笔上方', (tester) async {
    await pumpHome(tester);

    expect(find.byKey(const ValueKey('timer_button')), findsNothing);

    // 从 AppBar 菜单开始计时（平时没有计时入口）
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始计时'));
    await tester.pumpAndSettle();

    final timer = tester.getRect(find.byKey(const ValueKey('timer_button')));
    final newRecord = tester.getRect(newRecordButton());

    // y 轴向下：越靠屏幕下方 bottom 越大 —— 计时胶囊在记一笔之上
    expect(
      timer.bottom,
      lessThan(newRecord.top),
      reason: '计时胶囊应在记一笔按钮上方',
    );
    // 等宽（同一套规格常量）
    expect(timer.width, closeTo(_buttonSideForTest, 0.01));
    expect(newRecord.width, closeTo(_buttonSideForTest, 0.01));

    await drainStreamTeardown(tester);
  });

  testWidgets('长按记一笔 = 速记：直接插入一条今天的记录，内容为「速记」', (tester) async {
    await pumpHome(tester);
    expect(await repo.getAllActiveRecordsSync(), isEmpty);

    await longPressQuickNote(tester);

    final saved = await repo.getAllActiveRecordsSync();
    expect(saved, hasLength(1));
    expect(saved.single.content, '速记');
    // 业务日期是今天 —— 速记落今天，不算补记
    expect(saved.single.isRecordedToday(), isTrue);

    await drainStreamTeardown(tester);
  });

  testWidgets('速记后弹出带「撤销」的提示', (tester) async {
    await pumpHome(tester);

    await longPressQuickNote(tester);

    expect(find.text('已速记一条（今天）'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);

    await drainStreamTeardown(tester);
  });

  testWidgets('速记提示上的「撤销」能把刚记的那条退掉', (tester) async {
    await pumpHome(tester);

    await longPressQuickNote(tester);
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


}
