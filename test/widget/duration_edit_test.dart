// 编辑既有记录时「修改时长」的回归测试。
//
// 背景（2026-10-22 用户反馈）：
// 1. 修改时长有 bug；
// 2. 只能精确到分钟，秒级数据编辑一次就被截断（90 秒 → 打开弹层 → 确定 → 60 秒）。
// 这里钉住：改分钟档能生效并落库、秒级值原样保留、清除能生效。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/edit_screen.dart';

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  Future<void> pumpEdit(WidgetTester tester, String id) async {
    tester.view.physicalSize = const Size(412 * 3, 892 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: EditScreen(recordId: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('弹层里选 30 分钟 → 卡片更新 → 保存后落库 1800 秒', (tester) async {
    await repo.addRecord(content: '一条记录', durationSec: 45 * 60);
    final id = (await repo.getAllActiveRecordsSync()).single.id;

    await pumpEdit(tester, id);
    expect(find.text('45 分钟'), findsOneWidget);

    await tester.tap(find.text('时长（选填）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('30 分钟'), findsOneWidget, reason: '卡片应立即显示新值');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await repo.getAllActiveRecordsSync()).single;
    expect(saved.durationS, 1800, reason: '保存后库里的时长必须是 30 分钟');

    await drain(tester);
  });

  testWidgets('90 秒的记录：打开弹层直接确定，秒数不能被截断成 60', (tester) async {
    await repo.addRecord(content: '一条记录', durationSec: 90);
    final id = (await repo.getAllActiveRecordsSync()).single.id;

    await pumpEdit(tester, id);
    await tester.tap(find.text('时长（选填）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await repo.getAllActiveRecordsSync()).single;
    expect(saved.durationS, 90, reason: '没改任何东西，秒数必须原样保留');

    await drain(tester);
  });

  testWidgets('点「清除」→ 卡片回到未设置 → 保存后库里为 null', (tester) async {
    await repo.addRecord(content: '一条记录', durationSec: 600);
    final id = (await repo.getAllActiveRecordsSync()).single.id;

    await pumpEdit(tester, id);
    await tester.tap(find.text('时长（选填）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(find.text('点击填写 · 这次花了多久'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await repo.getAllActiveRecordsSync()).single;
    expect(saved.durationS, isNull, reason: '清除后库里应为 null');

    await drain(tester);
  });

  testWidgets('47 小时的记录：时轮能显示 47，不改任何东西也不会被截断', (tester) async {
    // 2026-10-27 审查 M-001：时轮原先固定 24 项，>24h 的值（跨天计时、CSV 导入）
    // 会让 FixedExtentScrollController(initialItem: 47) 越界，滚动位被夹到 23 ——
    // 用户一滚就把时长静默改小。这里钉住「47 有合法落点」与「原值不被改」。
    const longDuration = 47 * 3600 + 30 * 60; // 47 小时 30 分
    await repo.addRecord(content: '一条长记录', durationSec: longDuration);
    final id = (await repo.getAllActiveRecordsSync()).single.id;

    await pumpEdit(tester, id);
    await tester.tap(find.text('时长（选填）'));
    await tester.pumpAndSettle();

    // 时轮必须真的能落到 47（固定 24 项时这一项根本不存在）
    expect(find.text('47 时'), findsOneWidget, reason: '时轮项数应随当前值扩展');

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = (await repo.getAllActiveRecordsSync()).single;
    expect(
      saved.durationS,
      longDuration,
      reason: '只是打开又确定，时长必须一秒不差地保留',
    );

    await drain(tester);
  });
}
