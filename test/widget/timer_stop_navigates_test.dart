// 计时胶囊「停止 / 放弃」两条出口的回归测试。
//
// 背景（2026-10-28）：用户反馈「停止并记录 → 编辑页」要等好几秒。实测发现
// 比「慢」更糟 —— 大多数时候编辑页根本不出现：`stop()` 一开始就把 state 置
// null，首页立刻 rebuild，计时胶囊连同 `_TimerButton` 被整棵卸载；等 `await`
// 写盘回来，`if (!mounted) return` 把后续动作吞掉。表现为计时消失、人留在首页。
//
// 「放弃计时」走的是同一条路：`cancel()` 先置 null，再 await 写盘，回来后
// `mounted` 已是 false —— 那句 SnackBar 同样会被吞掉。
//
// 为什么必须注入一个「慢写盘」：测试环境里的 prefs 是同步的内存表，`await`
// 只跨一个 microtask，都在下一帧之前跑完 —— 竞态根本不会发生（旧代码也能
// 通过）。真机上 remove 要过平台通道，那点延迟才让 rebuild 抢先执行。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';

/// 写盘慢 200ms 的 SharedPreferences 替身（见文件头的说明）。
///
/// 只有 [remove]（停止 / 放弃时清起点）慢；读写计时起点都走真实语义 ——
/// `getInt` 必须返回 null 而不是抛错，否则 `durationTimerProvider.build`
/// 会直接进 error 状态，测试连计时都开不起来。
class _SlowSharedPreferences implements SharedPreferences {
  @override
  int? getInt(String key) => null;

  @override
  Future<bool> setInt(String key, int value) async => true;

  @override
  Future<bool> remove(String key) =>
      Future<bool>.delayed(const Duration(milliseconds: 200), () => true);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 起首页 → 菜单开始计时 → 点胶囊，停在「停止 / 放弃」确认框上。
///
/// 计时中每秒有一次 ticker，调用方之后不能再用 `pumpAndSettle`。
Future<void> _openStopDialog(WidgetTester tester, GoRouter router) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordsProvider.overrideWith(
          (ref) => Stream<List<RecordEntity>>.value(const <RecordEntity>[]),
        ),
        sharedPreferencesProvider.overrideWithValue(_SlowSharedPreferences()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('开始计时'));
  await tester.pump();

  await tester.tap(find.byKey(const ValueKey('timer_button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text('停止并记录'), findsOneWidget);
}

GoRouter _router() => GoRouter(
      initialLocation: AppRoutes.home,
      routes: <RouteBase>[
        GoRoute(path: AppRoutes.home, builder: (_, _) => const HomeScreen()),
        // 真实编辑页会牵出一整套表单，这里只关心「有没有被推出来」。
        GoRoute(
          path: AppRoutes.edit,
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('EDIT_PAGE'))),
        ),
      ],
    );

void main() {
  testWidgets('停止计时必须把编辑页推出来（写盘慢时也不能丢跳转）', (
    WidgetTester tester,
  ) async {
    final GoRouter router = _router();
    addTearDown(router.dispose);

    await _openStopDialog(tester, router);

    await tester.tap(find.text('停止并记录'));
    await tester.pump();
    // 跨过写盘那 200ms：旧顺序会在这段时间里把 _QuickDock 卸载掉。
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('EDIT_PAGE'),
      findsOneWidget,
      reason: '停止计时的唯一目的是带着时长去编辑页，跳转不能被 mounted 竞态吞掉',
    );

    // 排掉 ticker 与流的定时器。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('放弃计时必须给出提示（同一处 mounted 竞态）', (
    WidgetTester tester,
  ) async {
    final GoRouter router = _router();
    addTearDown(router.dispose);

    await _openStopDialog(tester, router);

    await tester.tap(find.text('放弃计时'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('已放弃本次计时'),
      findsOneWidget,
      reason: '放弃后既没跳转也没提示，用户无法确认这次计时是否真的取消',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
