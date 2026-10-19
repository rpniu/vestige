// 撤销功能**两个 UI 入口**的回归测试。
//
// 数据层的「撤销 = 回到操作前」已经由 `test/data/undo_test.dart` 钉住了；
// 这里补的是「用户点得到、点得对」那一层：
// 1. 首页 SnackBar 上的「撤销」真的会把刚做的操作退掉；
// 2. 「操作历史」弹层能列出条目、能回退，且**回退多步时会先问一次**。
//
// 这两条以前没有覆盖 —— 数据层全绿但入口接错线，用户一样用不了。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';
import 'package:vestige/presentation/widgets/undo_history_sheet.dart';

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;
  late RecordActions actions;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();

    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
    actions = RecordActions(repo);

    await repo.addRecord(
      id: 'a',
      content: '第一条',
      tags: <String>['x'],
      recordedAt: DateTime(2026, 9, 20, 9),
    );
    await repo.addRecord(
      id: 'b',
      content: '第二条',
      recordedAt: DateTime(2026, 9, 21, 9),
    );
  });

  tearDown(() => db.close());

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
          theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder selectAllBox() => find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Checkbox),
      );

  /// 收尾：把 drift 流的销毁定时器走完。
  ///
  /// 必须写在**测试体末尾**，不能放 `addTearDown` —— 框架的
  /// `_verifyInvariants`（检查有没有挂着的定时器）在 `_runTestBody` 末尾就跑，
  /// 早于 tearDown 回调。
  ///
  /// 为什么只有这个文件需要它：别的 widget 测试都把 `recordsProvider` /
  /// `trashProvider` override 成了 `Stream.value(...)`，压根没接真实 drift 流；
  /// 这里用了真实内存库，ProviderScope 销毁时 drift 会排一个零延迟定时器去标记
  /// 流已关闭，不等它跑完就报「A Timer is still pending…」。
  Future<void> drainStreamTeardown(WidgetTester tester) async {
    // 换掉整棵树 → ProviderScope 销毁 → drift 取消订阅 → 定时器被排出来
    await tester.pumpWidget(const SizedBox());
    // 让那个零延迟定时器跑掉
    await tester.pump(Duration.zero);
  }

  testWidgets('首页 SnackBar 上的「撤销」真的把批量打标签退掉了', (tester) async {
    await pumpHome(tester);

    // 长按进多选 → 全选两条
    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(selectAllBox());
    await tester.pumpAndSettle();

    // 批量给两条都加上 #x（a 本来就有 x，对它是空操作）
    await tester.tap(find.byTooltip('批量打标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '#x'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '加上这些'));
    await tester.pumpAndSettle();

    expect((await repo.getRecordById('a'))!.tags, <String>['x']);
    expect((await repo.getRecordById('b'))!.tags, <String>['x']);

    // SnackBar 上该有「撤销」，点它
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(
      (await repo.getRecordById('a'))!.tags,
      <String>['x'],
      reason: 'a 本来就有的标签不该被撤销删掉 —— 这正是必须存快照的原因',
    );
    expect((await repo.getRecordById('b'))!.tags, isEmpty);

    await drainStreamTeardown(tester);
  });

  testWidgets('首页 SnackBar 上的「撤销」也能把「移入回收站」退掉', (tester) async {
    await pumpHome(tester);

    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(selectAllBox());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移入回收站'));
    await tester.pumpAndSettle();

    expect(await repo.getAllActiveRecordsSync(), isEmpty);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect((await repo.getAllActiveRecordsSync()).length, 2);
    expect(
      (await repo.getRecordById('a'))!.deletedAt,
      isNull,
      reason: '撤销要把 deletedAt 清回 null，否则一回到列表就被保留期判成超期',
    );

    await drainStreamTeardown(tester);
  });

  testWidgets('带「撤销」的提示会自己消失（persist 必须显式为 false）', (tester) async {
    await pumpHome(tester);

    // 造一条带撤销的提示：批量打标签
    await tester.longPress(find.byType(RecordCard).first);
    await tester.pumpAndSettle();
    await tester.tap(selectAllBox());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量打标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '#x'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '加上这些'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget, reason: '操作后先给提示');

    // 走完提示时长（3 秒）+ 淡出动画
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(
      find.byType(SnackBar),
      findsNothing,
      reason:
          'SnackBar 的 persist 默认是 `action != null` —— 带按钮的提示条默认永不消失，'
          '不显式写 `persist: false` 的话 duration 会被完全忽略，提示一直挂在屏幕上',
    );

    await drainStreamTeardown(tester);
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
        ],
        child: MaterialApp(
          theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const Scaffold(body: UndoHistorySheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('操作历史：没有历史时给说明文案，不是空白', (tester) async {
    await pumpSheet(tester);
    expect(find.text('操作历史'), findsOneWidget);
    expect(find.textContaining('还没有可回退的操作'), findsOneWidget);
    expect(
      find.widgetWithText(TextButton, '清空'),
      findsNothing,
      reason: '没有历史就没有可清的东西，入口不该出现',
    );
  });

  testWidgets('操作历史：列出条目；退最近一步不用二次确认', (tester) async {
    await actions.applyTags(<String>['b'], add: <String>['y']);
    await pumpSheet(tester);

    expect(find.text('批量改标签'), findsOneWidget);
    expect(find.textContaining('影响 1 条'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '回退'));
    await tester.pumpAndSettle();

    // 只有一步 → 不该弹确认框
    expect(find.text('一并回退更新的操作？'), findsNothing);
    expect((await repo.getRecordById('b'))!.tags, isEmpty);
  });

  testWidgets('操作历史：退更早的一步时，先说明会一并回退更新的操作', (tester) async {
    await actions.applyTags(<String>['b'], add: <String>['y']);
    await actions.shiftDay(<String>['b'], 1);
    await pumpSheet(tester);

    // 列表新的在前：第 0 行是「日期后移」，第 1 行是「批量改标签」
    expect(find.text('日期后移 1 天'), findsOneWidget);
    expect(find.text('批量改标签'), findsOneWidget);

    // 点更早那一步的「回退」（第二行）
    await tester.tap(find.widgetWithText(TextButton, '回退').last);
    await tester.pumpAndSettle();

    expect(find.text('一并回退更新的操作？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '一并回退'));
    await tester.pumpAndSettle();

    // 两步一起回滚 → 回到最初：没标签、日期回到 9/21
    final b = (await repo.getRecordById('b'))!;
    expect(b.tags, isEmpty);
    expect(b.recordedAt, DateTime(2026, 9, 21, 9));
    expect(find.textContaining('还没有可回退的操作'), findsOneWidget);
  });

  testWidgets('操作历史：单条删除只去掉那一条，记录数据不动', (tester) async {
    await actions.applyTags(<String>['b'], add: <String>['y']);
    await actions.shiftDay(<String>['b'], 1);
    await pumpSheet(tester);

    // 删最新那条（列表第一行：日期后移）
    await tester.tap(find.byTooltip('删除这条历史').first);
    await tester.pumpAndSettle();

    expect(find.text('日期后移 1 天'), findsNothing);
    expect(find.text('批量改标签'), findsOneWidget);
    expect(
      (await repo.getRecordById('b'))!.tags,
      <String>['y'],
      reason: '删历史 ≠ 删数据',
    );
  });

  testWidgets('操作历史：清空要过确认框；取消不动，确认后连入口一起消失', (tester) async {
    await actions.applyTags(<String>['b'], add: <String>['y']);
    await pumpSheet(tester);

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空操作历史？'), findsOneWidget);

    // 取消：什么都没发生
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('批量改标签'), findsOneWidget);

    // 再点开，这次确认。对话框里的「清空」要和标题行的同名按钮区分开，
    // 用 AlertDialog 作用域收敛
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '清空'),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有可回退的操作'), findsOneWidget);
    expect(
      find.widgetWithText(TextButton, '清空'),
      findsNothing,
      reason: '空了之后标题行的清空入口也该消失',
    );
    expect(await actions.recentUndo(), isEmpty);
    expect((await repo.getRecordById('b'))!.tags, <String>['y']);
  });

  testWidgets('操作历史：加载出错时显示错误与重试，不是无限转圈', (tester) async {
    // 库打不开（迁移失败、文件损坏）时 recentUndo 会 reject。Future 出错时
    // snapshot.data 同样是 null —— 旧代码对 error 和 loading 一视同仁，
    // 结果就是永远转圈（2026-09-24 模拟器上数据库打不开时的真实表现）。
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          recordActionsProvider
              .overrideWithValue(_FailingRecentUndoActions(repo)),
        ],
        child: MaterialApp(
          theme:
              buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const Scaffold(body: UndoHistorySheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('历史加载失败'), findsOneWidget);
    expect(find.textContaining('库打不开'), findsOneWidget,
        reason: '错误详情要露出来 —— 报障截图里它能定位问题');
    expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '转圈只在「还在等」的时候合法；出错后继续转圈 = 永远没有出口',
    );
  });
}

/// recentUndo 永远抛错 —— 模拟「数据库打不开」的失败态。
class _FailingRecentUndoActions extends RecordActions {
  _FailingRecentUndoActions(RecordRepository repo) : super(repo);

  @override
  Future<List<UndoEntryEntity>> recentUndo() async {
    throw StateError('库打不开（模拟迁移失败）');
  }
}
