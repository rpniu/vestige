// 编辑页保存 / 删除之后的「撤销」提示（2026-11-01）。
//
// 盯两件事：
// 1. 提示条要在**退回上一页之后**出现 —— 编辑页保存完就 pop，读 `context`
//    已经失效，所以 messenger 必须在 pop 之前取出。这个顺序写反了不会报错，
//    只会静默地什么都不显示，因此必须有用例守着；
// 2. 点「撤销」真的能退回保存前：修改走快照写回，新建走 insertedIds 删除。

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

  /// 起「上一页 + 编辑页」两层：只有真的 push 进去，才能验证 pop 之后
  /// 提示条是否还挂得住。
  Future<void> pumpFromHost(WidgetTester tester, {String? recordId}) async {
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
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => recordId == null
                          ? const EditScreen()
                          : EditScreen(recordId: recordId),
                    ),
                  ),
                  child: const Text('打开编辑页'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开编辑页'));
    await tester.pumpAndSettle();
  }

  /// 内容输入框（按标签定位：标题框也在这一页，按类型取会拿错）。
  Finder contentField() => find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.labelText == '内容（必填）',
      );

  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  testWidgets('修改后保存：退回上一页仍给出「撤销」，点了内容回原样', (tester) async {
    await repo.addRecord(id: 'r1', content: '原内容');
    await pumpFromHost(tester, recordId: 'r1');

    await tester.enterText(contentField(), '改过的内容');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('已保存修改'), findsOneWidget, reason: '提示条要落在上一页上');
    expect(find.text('撤销'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(
      (await repo.getRecordById('r1'))!.content,
      '原内容',
      reason: '撤销编辑保存 = 按快照整行写回',
    );

    await drain(tester);
  });

  testWidgets('新建保存后撤销：这一条彻底消失', (tester) async {
    await pumpFromHost(tester);

    await tester.enterText(contentField(), '新写的一条');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('已记下这一条'), findsOneWidget);
    expect(await repo.getAllActiveRecordsSync(), hasLength(1));

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(await repo.getAllActiveRecordsSync(), isEmpty);
    expect(
      await repo.getDeletedRecords(),
      isEmpty,
      reason: '撤销新增是删除，不是丢进回收站',
    );

    await drain(tester);
  });

  testWidgets('编辑页删除：退回上一页后仍是「撤销」，点了记录回到列表', (tester) async {
    await repo.addRecord(id: 'r2', content: '要删的');
    await pumpFromHost(tester, recordId: 'r2');

    await tester.tap(find.byTooltip('移入回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '移入回收站'));
    await tester.pumpAndSettle();

    expect(find.text('已移入回收站'), findsOneWidget);
    expect(await repo.getAllActiveRecordsSync(), isEmpty);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    final back = await repo.getRecordById('r2');
    expect(back, isNotNull, reason: '撤销「移入回收站」要把整行写回');
    expect(back!.deleted, isFalse);
    expect(await repo.getAllActiveRecordsSync(), hasLength(1));

    await drain(tester);
  });
}
