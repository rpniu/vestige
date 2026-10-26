// 首页标签筛选的回归测试。
//
// 三层：
// 1. provider 层（不起 widget）：tagCounts 的统计与排序、选中标签后
//    homeRows 的过滤（空组消失、分组头条数换成过滤后的）、失效标签自动回退成无筛选；
// 2. 页面层：入口按钮的出现/消失、弹层里挑标签、筛选指示条与「清除筛选」；
// 3. 主页上**不再**常驻标签 chip —— 这是这次改版的核心约束，
//    没有入口/弹层干扰时主页不该出现任何标签文字。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

RecordEntity _rec(
  String id,
  DateTime day, {
  String content = '1',
  List<String> tags = const <String>[],
}) =>
    RecordEntity(
      id: id,
      title: null,
      content: content,
      tags: tags,
      recordedAt: day,
      createdAt: day,
      updatedAt: day,
      deleted: false,
    );

final DateTime _today = DateTime.now();

List<RecordEntity> _seed() => <RecordEntity>[
      _rec('a', _today, content: '带生活标签', tags: <String>['生活']),
      _rec('b', _today, content: '生活加咖啡', tags: <String>['生活', '咖啡']),
      _rec(
        'c',
        _today.subtract(const Duration(days: 1)),
        content: '只有咖啡',
        tags: <String>['咖啡'],
      ),
      _rec('d', _today.subtract(const Duration(days: 1)), content: '没标签'),
    ];

/// 打开标签弹层（点 AppBar 上那个入口按钮）。
///
/// 入口按钮的 tooltip 会随筛选状态变（未筛选 =「按标签筛选」，
/// 筛选中 =「筛选：#xx」），所以这里不能钉死一个 tooltip —— 按前缀找。
Future<void> _openTagSheet(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (w) =>
          w is IconButton &&
          (w.tooltip == '按标签筛选' || (w.tooltip?.startsWith('筛选：#') ?? false)),
    ),
  );
  await tester.pumpAndSettle();
}

/// 弹层里某一行标签 —— 必须按 `ListTile` 收敛查找范围：
/// `#咖啡` 这种文字在记录卡自己的元信息行里也会出现（卡上印着标签），
/// 直接 `find.text('#咖啡')` 会同时命中卡上的那个。
Finder _sheetTag(String tag) =>
    find.widgetWithText(ListTile, '#$tag');

/// 关掉弹层（点遮罩：`showModalBottomSheet` 的 barrier）。
Future<void> _dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

/// 弹层标题栏那个**全选框** —— 它是唯一不在 `ListTile` 里的 `Checkbox`
/// （每个标签行的复选框都在 `ListTile.leading` 里）。
/// 加了全选之后，`find.byType(Checkbox)` 数出来的是「标签数 + 1」，
/// 所有按行数断言的测试都得用这个把全选框排除掉。
Finder _selectAllBox() => find.byWidgetPredicate(
      (w) =>
          w is Checkbox &&
          find
              .descendant(of: find.byType(ListTile), matching: find.byWidget(w))
              .evaluate()
              .isEmpty,
    );

/// 弹层里**每行标签**各自的复选框（不含标题栏的全选框）。
Finder _rowBoxes() => find.descendant(
      of: find.byType(ListTile),
      matching: find.byType(Checkbox),
    );

/// 指示条上的某个标签 chip —— 同样要收敛范围：
/// `#咖啡` 在卡片自己的元信息行里也有（卡上印着标签），
/// 而指示条的 chip 是「带一个 close 图标」的那个，用它来区分。
Finder _bannerChip(String tag) => find.ancestor(
      of: find.text('#$tag'),
      matching: find.byWidgetPredicate(
        (w) => w is Row && w.children.any((c) => c is Icon && c.icon == Icons.close_rounded),
      ),
    );

void main() {
  group('provider 层', () {
    test('tagCountsProvider：统计条数，按条数降序、同数按名称', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => Stream.value(_seed())),
        ],
      );
      addTearDown(container.dispose);
      await container.read(recordsProvider.future);

      final tags = container.read(tagCountsProvider);
      // 「生活」与「咖啡」同为 2 条，按码位排序「咖啡」在前
      expect(tags.map((t) => t.tag), <String>['咖啡', '生活']);
      expect(tags.map((t) => t.count), <int>[2, 2]);
    });

    test('勾选单个标签后：homeRows 只剩该标签的记录，空组整组消失', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => Stream.value(_seed())),
        ],
      );
      addTearDown(container.dispose);
      await container.read(recordsProvider.future);

      container.read(selectedTagsProvider.notifier).toggle('咖啡');
      final rows = container.read(homeRowsProvider);

      final records = rows.whereType<RecordRow>().map((r) => r.record.id);
      expect(records, <String>['b', 'c']);

      // 今天这一组过滤后只剩 b 一条，分组头条数必须是过滤后的 1
      final headers = rows.whereType<DayHeaderRow>().toList();
      expect(headers.length, 2, reason: '两天各有 1 条命中，两组都该在');
      expect(headers.first.group.count, 1);
    });

    test('复选多个标签：取「或」并集，且不会把前一个标签挤掉', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => Stream.value(_seed())),
        ],
      );
      addTearDown(container.dispose);
      await container.read(recordsProvider.future);

      final notifier = container.read(selectedTagsProvider.notifier);
      notifier.toggle('咖啡');
      notifier.toggle('生活');

      // 复选：两个都在
      expect(container.read(selectedTagsProvider), <String>{'咖啡', '生活'});

      // 「或」语义：a(生活) b(生活+咖啡) c(咖啡) 命中，d(无标签) 不命中
      final ids = container
          .read(homeRowsProvider)
          .whereType<RecordRow>()
          .map((r) => r.record.id)
          .toList();
      expect(ids..sort(), <String>['a', 'b', 'c']);

      // 条数按并集算，不是两个标签条数之和（2 + 2 = 4，并集只有 3）
      expect(container.read(filteredRecordCountProvider), 3);

      // 反选掉一个，另一个还在
      notifier.toggle('生活');
      expect(container.read(selectedTagsProvider), <String>{'咖啡'});
      expect(container.read(filteredRecordCountProvider), 2);
    });

    test('标签随记录消失后，失效筛选自动回退成「无筛选」', () async {
      final controller = StreamController<List<RecordEntity>>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);

      controller.add(_seed());
      await container.read(recordsProvider.future);
      container.read(selectedTagsProvider.notifier).toggle('咖啡');
      expect(
        container.read(homeRowsProvider).whereType<RecordRow>().length,
        2,
      );

      // 把带「咖啡」的记录全删掉 → 筛选失效 → 列表回到未过滤的剩余全量
      controller.add(<RecordEntity>[
        _rec('d', _today.subtract(const Duration(days: 1)), content: '没标签'),
      ]);
      await container.read(recordsProvider.future);
      expect(
        container.read(homeRowsProvider).whereType<RecordRow>().length,
        1,
        reason: '「咖啡」已不存在，筛选自动失效，应显示剩余全部记录',
      );
    });

    test('部分标签失效：只剔掉失效的那个，其余勾选照旧生效', () async {
      final controller = StreamController<List<RecordEntity>>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        overrides: <Override>[
          recordsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);

      controller.add(_seed());
      await container.read(recordsProvider.future);
      final notifier = container.read(selectedTagsProvider.notifier);
      notifier.toggle('咖啡');
      notifier.toggle('生活');
      expect(container.read(effectiveTagFilterProvider), <String>{'咖啡', '生活'});

      // 「咖啡」消失了，但「生活」还在 → 只剩它生效
      controller.add(<RecordEntity>[
        _rec('a', _today, content: '带生活标签', tags: <String>['生活']),
        _rec('d', _today.subtract(const Duration(days: 1)), content: '没标签'),
      ]);
      await container.read(recordsProvider.future);

      expect(
        container.read(effectiveTagFilterProvider),
        <String>{'生活'},
        reason: '只剔掉失效的标签，不该把整个筛选清空',
      );
      expect(container.read(selectedTagsProvider), <String>{'咖啡', '生活'},
          reason: '原始勾选状态保留 —— 标签可能只是这一批数据里暂时没有');
      expect(container.read(filteredRecordCountProvider), 1);
    });
  });

  group('页面层', () {
    Future<void> pumpHome(
      WidgetTester tester,
      List<RecordEntity> records,
    ) async {
      tester.view.physicalSize = const Size(412 * 3, 892 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            recordsProvider.overrideWith((ref) => Stream.value(records)),
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

    testWidgets('主页不再常驻标签栏：没有 chip、没有横滑栏、没有筛选指示', (tester) async {
      await pumpHome(tester, _seed());

      // 4 条记录都在
      expect(find.byType(RecordCard), findsNWidgets(4));
      // 原来那条横滑 chip 过滤栏必须彻底消失（这是这次改版的核心约束）
      expect(find.byType(FilterChip), findsNothing);
      // 也没进筛选状态：指示条与「清除筛选」都不该出现
      expect(find.text('清除筛选'), findsNothing);
      // 入口按钮在，且是「未筛选」的描边态
      expect(find.byTooltip('按标签筛选'), findsOneWidget);
      expect(find.byTooltip('筛选：#咖啡'), findsNothing);
      expect(find.byTooltip('筛选：#生活'), findsNothing);

      // 弹层没开的时候也不该有复选框 —— 复选只发生在弹层里
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('弹层里是复选框；勾一个过滤、再点一次取消', (tester) async {
      await pumpHome(tester, _seed());
      expect(find.byType(RecordCard), findsNWidgets(4));

      await _openTagSheet(tester);
      // 两个标签 = 两个行内复选框（外加标题栏那个全选框）；都未勾选
      expect(_rowBoxes(), findsNWidgets(2));
      expect(_selectAllBox(), findsOneWidget);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).every((c) => c.value != true),
        isTrue,
      );
      expect(_sheetTag('咖啡'), findsOneWidget);
      expect(_sheetTag('生活'), findsOneWidget);
      // 「2 条」在卡片分组头里也有，所以按弹层行收敛
      expect(find.descendant(of: find.byType(ListTile), matching: find.text('2 条')),
          findsNWidgets(2));
      expect(find.text('全部 4'), findsOneWidget);

      // 勾「咖啡」→ 关掉弹层看列表
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);

      expect(find.byType(RecordCard), findsNWidgets(2));
      expect(find.text('只有咖啡'), findsOneWidget);
      expect(find.text('没标签'), findsNothing);
      expect(find.byTooltip('筛选：#咖啡'), findsOneWidget);

      // 再进弹层点同一个标签 = 取消勾选
      await _openTagSheet(tester);
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);

      expect(find.byType(RecordCard), findsNWidgets(4));
      expect(find.byTooltip('筛选：#咖啡'), findsNothing);
    });

    testWidgets('复选：勾第二个标签不挤掉第一个，两个复选框同时勾着', (tester) async {
      await pumpHome(tester, _seed());

      await _openTagSheet(tester);
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetTag('生活'));
      await tester.pumpAndSettle();

      // 弹层里两个行内复选框都是勾上的（这就是「复选」与「单选」的分别）
      final values = tester
          .widgetList<Checkbox>(_rowBoxes())
          .map((c) => c.value)
          .toList();
      expect(values, <bool?>[true, true]);
      // 标题边上报出勾选个数
      expect(find.text('已选 2'), findsOneWidget);

      await _dismissSheet(tester);

      // 并集：a(生活) b(生活+咖啡) c(咖啡) 三条，d 除外
      expect(find.byType(RecordCard), findsNWidgets(3));
      expect(find.text('没标签'), findsNothing);
      expect(find.byTooltip('筛选：已选 2 个标签'), findsOneWidget);
    });

    testWidgets('指示条上每个标签都能单独去掉', (tester) async {
      await pumpHome(tester, _seed());

      await _openTagSheet(tester);
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetTag('生活'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);
      expect(find.byType(RecordCard), findsNWidgets(3));

      // 指示条上是可横滑的 chip：点「#咖啡」那个 = 只去掉咖啡
      await tester.tap(_bannerChip('咖啡'));
      await tester.pumpAndSettle();

      expect(find.byType(RecordCard), findsNWidgets(2), reason: '只剩「生活」的 2 条');
      expect(find.byTooltip('筛选：#生活'), findsOneWidget);
      expect(find.text('清除筛选'), findsOneWidget, reason: '还有一个标签在，指示条不该消失');
    });

    testWidgets('指示条上的「清除筛选」一键回到全部', (tester) async {
      await pumpHome(tester, _seed());

      await _openTagSheet(tester);
      await tester.tap(_sheetTag('生活'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);
      expect(find.byType(RecordCard), findsNWidgets(2));

      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();

      expect(find.byType(RecordCard), findsNWidgets(4));
      expect(find.text('清除筛选'), findsNothing);
    });

    testWidgets('弹层标题栏的「全部 N」= 清除筛选', (tester) async {
      await pumpHome(tester, _seed());

      await _openTagSheet(tester);
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      // 再勾一个，确认「全部」能把多个一起清掉
      await tester.tap(_sheetTag('生活'));
      await tester.pumpAndSettle();
      // 弹层还开着，点「全部 4」
      await tester.tap(find.text('全部 4'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsNothing);
      await _dismissSheet(tester);

      expect(find.byType(RecordCard), findsNWidgets(4));
      expect(find.text('清除筛选'), findsNothing);
    });

    testWidgets('没有任何标签时入口按钮不出现', (tester) async {
      await pumpHome(tester, <RecordEntity>[_rec('x', _today)]);
      expect(find.byTooltip('按标签筛选'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('弹层标题栏的全选框：部分选中 → 全选 → 再点清空', (tester) async {
      await pumpHome(tester, _seed());
      await _openTagSheet(tester);

      Checkbox boxValue() => tester.widget<Checkbox>(_selectAllBox());

      // 一开始：一个都没勾 → 全选框为 false
      expect(boxValue().value, isFalse);

      // 勾一个 → 部分选中 → 全选框变 tristate 的 null
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      expect(boxValue().value, isNull, reason: '勾了一个但没全勾 = 部分选中');

      // 点全选框 → 全部标签都勾上（行内两个复选框都变 true）
      await tester.tap(_selectAllBox());
      await tester.pumpAndSettle();
      expect(boxValue().value, isTrue);
      expect(find.text('已选 2'), findsOneWidget);
      expect(
        tester.widgetList<Checkbox>(_rowBoxes()).map((c) => c.value),
        <bool?>[true, true],
      );

      // 再点一次 → 全部清空
      await tester.tap(_selectAllBox());
      await tester.pumpAndSettle();
      expect(boxValue().value, isFalse);
      expect(find.text('已选 2'), findsNothing);
      expect(
        tester.widgetList<Checkbox>(_rowBoxes()).map((c) => c.value),
        <bool?>[false, false],
      );

      await _dismissSheet(tester);
      expect(find.byType(RecordCard), findsNWidgets(4));
    });

    testWidgets('全选所有标签后关掉弹层：列表显示全部记录（并集 = 全集）', (tester) async {
      await pumpHome(tester, _seed());
      await _openTagSheet(tester);

      // 直接勾两个标签（等于全集），关掉弹层验证列表没被筛空
      await tester.tap(_sheetTag('咖啡'));
      await tester.pumpAndSettle();
      await tester.tap(_sheetTag('生活'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);

      // a(生活) b(生活+咖啡) c(咖啡) 命中；d(无标签) 不命中 —— 并集不是全集
      expect(find.byType(RecordCard), findsNWidgets(3));
    });

    testWidgets('标签很多：弹层可滚，最后一排标签也点得到', (tester) async {
      // 15 个标签，六成屏高放不下，弹层列表必须能滚
      final records = <RecordEntity>[
        for (var i = 0; i < 15; i++)
          _rec('t$i', _today, content: '标签 $i', tags: <String>['标签$i']),
      ];
      await pumpHome(tester, records);
      await _openTagSheet(tester);

      expect(find.byType(ListTile), findsWidgets);

      await tester.scrollUntilVisible(
        _sheetTag('标签14'),
        120,
        scrollable: find
            .byWidgetPredicate((w) => w is Scrollable)
            .last,
      );
      await tester.tap(_sheetTag('标签14'));
      await tester.pumpAndSettle();
      await _dismissSheet(tester);

      expect(find.byType(RecordCard), findsOneWidget);
      expect(find.text('标签 14'), findsOneWidget);
    });
  });
}
