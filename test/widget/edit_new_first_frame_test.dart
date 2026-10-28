// 「新建记录不再先闪一帧转圈」的回归测试。
//
// 背景（2026-10-28）：编辑页用 `async.when(loading: 转圈)` 渲染。新建记录时
// provider 的 build 其实同步 return（日期与时长都编码在 family key 里），
// 但 AsyncNotifier 至少要等一次异步边界才把值交出来，于是第一帧必然是转圈 ——
// 从计时器「停止并记录」进来时，这一下转圈紧接着页面转场，看着像卡了一拍。
//
// 现在页面在新建时先用 `newRecordStateFromKey` 画出表单，等真值到了再换。
// 这里只 pump 一帧（不 settle），确保「首帧就是表单」。

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
  testWidgets('新建记录首帧就是表单，不再闪转圈', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final VestigeDatabase db = VestigeDatabase(NativeDatabase.memory());
    RecordRepository(db.recordDao);
    addTearDown(db.close);

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
          home: const EditScreen(initialDurationSec: 90),
        ),
      ),
    );

    // 关键断言：只过了一帧，provider 的异步值还没到。
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '新建没有任何 IO，首帧不该是转圈',
    );
    expect(find.text('新建记录'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('新建记录'), findsOneWidget);

    // 排掉数据库流的销毁定时器。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
