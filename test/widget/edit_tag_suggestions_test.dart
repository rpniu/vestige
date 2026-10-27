// 编辑页「历史标签」的回归测试：
// 1. 标签卡下方的建议区：按条数降序、点一下直接加入、已加入的不再出现、最多 10 个；
// 2. 添加框里的建议：空输入显示最常用的 6 个、输入即时过滤、点建议直接选中、
//    已在本条记录上的标签不进建议。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/edit_record_provider.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/edit_screen.dart';

RecordEntity _rec(String id, List<String> tags) {
  final now = DateTime.now();
  return RecordEntity(
    bookId: 'default',
    id: id,
    title: null,
    content: '1',
    tags: tags,
    recordedAt: now,
    createdAt: now,
    updatedAt: now,
    deleted: false,
  );
}

void main() {
  Future<ProviderContainer> pumpEdit(
    WidgetTester tester,
    List<RecordEntity> records,
  ) async {
    tester.view.physicalSize = const Size(412 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => Stream.value(records)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme:
              buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
          home: const EditScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// 本条记录当前的标签（新建页 family key 是 `new`）。
  List<String> editTags(ProviderContainer container) =>
      container.read(editRecordProvider(kNewRecordId)).valueOrNull?.tags ??
      const <String>[];

  testWidgets('建议区按条数降序；点一下直接加入本条；加入后不再出现', (tester) async {
    final container = await pumpEdit(tester, <RecordEntity>[
      _rec('a', <String>['生活']),
      _rec('b', <String>['生活', '咖啡']),
      _rec('c', <String>['生活', '咖啡']),
      _rec('d', <String>['开发']),
    ]);

    expect(find.text('历史标签 · 点一下加入'), findsOneWidget);
    // 降序：生活(3) 在 咖啡(2) 左，咖啡 在 开发(1) 左
    final lifeX = tester.getCenter(find.text('#生活')).dx;
    final coffeeX = tester.getCenter(find.text('#咖啡')).dx;
    final devX = tester.getCenter(find.text('#开发')).dx;
    expect(lifeX, lessThan(coffeeX));
    expect(coffeeX, lessThan(devX));

    await tester.tap(find.text('#生活'));
    await tester.pumpAndSettle();
    expect(editTags(container), contains('生活'));
    // 已加入的标签从建议区消失（剩下的唯一「#生活」是已添加区那颗）
    expect(find.text('#生活'), findsOneWidget);
    expect(find.text('#咖啡'), findsOneWidget);
  });

  testWidgets('历史标签超过 10 个时只摆 10 个', (tester) async {
    await pumpEdit(tester, <RecordEntity>[
      for (var i = 0; i < 12; i++) _rec('t$i', <String>['标签$i']),
    ]);
    // 12 个同为 1 条，按码位序取前 10：标签0,1,10,11,2..7
    expect(find.text('#标签7'), findsOneWidget);
    expect(find.text('#标签8'), findsNothing);
    expect(find.text('#标签9'), findsNothing);
  });

  testWidgets('添加框：空输入显示 6 个；输入即时过滤；点建议直接加入', (tester) async {
    final container = await pumpEdit(tester, <RecordEntity>[
      for (var i = 0; i < 8; i++) _rec('t$i', <String>['标签$i']),
      _rec('c1', <String>['咖啡']),
      _rec('c2', <String>['咖啡馆日记']),
    ]);

    await tester.tap(find.text('添加标签'));
    await tester.pumpAndSettle();

    // 空输入：对话框里 6 个建议（最常用地排前）
    expect(find.text('历史标签'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(ActionChip),
      ),
      findsNWidgets(6),
    );

    // 输入「咖」→ 只剩包含它的两个（对话框内唯一的输入框）
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '咖',
    );
    await tester.pumpAndSettle();
    expect(find.text('匹配的历史标签'), findsOneWidget);

    // 断言与点击都限定在对话框内（页面上还有一层建议区，文本会撞名）
    Finder inDialog(String text) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(text),
        );
    expect(inDialog('#咖啡'), findsOneWidget);
    expect(inDialog('#咖啡馆日记'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(ActionChip),
      ),
      findsNWidgets(2),
    );

    // 点建议 = 直接选中并关闭
    await tester.tap(inDialog('#咖啡'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(editTags(container), contains('咖啡'));

    // 再打开：已加入的「咖啡」不再出现在建议里
    await tester.tap(find.text('添加标签'));
    await tester.pumpAndSettle();
    expect(inDialog('#咖啡'), findsNothing);
    expect(inDialog('#咖啡馆日记'), findsOneWidget);
  });
}
