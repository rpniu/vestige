// 2026-10-27 审查 C-001 的回归测试：数据层失败必须显示错误态，而不是空列表。
//
// 背景：首页 / 统计 / 我的原先都用 `valueOrNull` 把 AsyncError 折成空集合，
// 于是「库打不开、迁移失败」在界面上与「一条记录都没有」完全一致 ——
// 2026-09-24 那次真实事故就是这样被误读成「数据丢了」的。
//
// 这里把 recordsProvider 直接换成一条 error 流，断言：
// 1. 首页出现错误态（含重试入口），且**不出现**空态文案；
// 2. 统计页整页切错误态，而不是四张全 0 的卡；
// 3. 我的页头卡说「记录读取失败」，不写「共 0 条记录」。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/screens/profile_screen.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';

void main() {
  late VestigeDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    db = VestigeDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// 让 recordsProvider 直接失败 —— 等价于「库打不开 / 查询抛异常」。
  Future<void> pumpWithBrokenDb(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(412 * 3, 892 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordsProvider.overrideWith(
            (ref) => Stream<List<RecordEntity>>.error(
              StateError('database is locked'),
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('首页：出错时显示错误态 + 重试，而不是「还没有任何记录」', (tester) async {
    await pumpWithBrokenDb(tester, const HomeScreen());

    expect(find.text('数据读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(
      find.text('还没有任何记录'),
      findsNothing,
      reason: '错误被当成空态就是这次修复要杜绝的事',
    );
    // 错误详情要能看见（报障截图能定位）
    expect(find.textContaining('database is locked'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('统计页：出错时整页切错误态，不显示全 0 的统计卡', (tester) async {
    await pumpWithBrokenDb(tester, const StatsScreen());

    expect(find.text('数据读取失败'), findsOneWidget);
    expect(find.text('月度分布'), findsNothing, reason: '出错时不该渲染数据卡');

    await drain(tester);
  });

  testWidgets('我的页：头卡说「记录读取失败」，不写「共 0 条记录」', (tester) async {
    await pumpWithBrokenDb(tester, const ProfileScreen());

    expect(find.text('记录读取失败'), findsOneWidget);
    expect(find.text('共 0 条记录'), findsNothing);

    await drain(tester);
  });
}
