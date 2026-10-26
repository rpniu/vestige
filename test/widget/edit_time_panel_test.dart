// 新建 / 编辑页「记录日期」卡的版式回归测试。
//
// 改版轨迹（2026-09-17）：
// ① 最早是「1 直接输入」+「或」+「2 用日历、时钟选择」两个并列区块，读起来像必须二选一；
// ② 后来合并成一个面板，但主入口仍是年月日 / 时分的数字框，日历 / 时钟只是行尾的附属按钮；
// ③ 现在**彻底删掉键盘输入** —— 面板只剩两行入口：日期行（日历）、时间行（时钟）。
//
// 这里钉住三件事：
// 1. 面板里不再有可键盘输入的控件（数字框连同「年 / 月 / 日 / 时 / 分」注脚一起消失），
//    更早那版的编号、「或」分隔线也不会回来；
// 2. 两行的几何关系：日期在上、时间在下，两个按钮右对齐成一列、各自与自己那一行齐平、
//    且都在面板内部 —— 版式回归量坐标最直接，也不受字体差异影响；
// 3. 入口真的能改值：日历选完日期行的值跟着变，时钟取消则什么都不动。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/screens/edit_screen.dart';

const String _calTip = '用日历挑选日期';
const String _clockTip = '用时钟挑选时刻';

Future<void> _pumpEdit(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 900) * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildVestigeTheme(AppThemeVariant.defaultBlue, Brightness.light),
        // 与 lib/main.dart 保持一致：只声明 zh_CN（App 未接 AppLocalizations，
        // 没有英文界面）。delegates 必须留着 —— 「确定 / 取消」这些断言文案
        // 就是 GlobalMaterialLocalizations 提供的中文。
        locale: const Locale('zh', 'CN'),
        supportedLocales: const <Locale>[Locale('zh', 'CN')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const EditScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 时间面板本身：凹槽底、带描边的那个 `Material`。
///
/// 取的是**最近的** Material 祖先 —— `_PickerButton` 自己也是一层 Material，
/// 但它在按钮内部（后代），不在祖先链上，所以 `.first` 拿到的就是面板。
Finder _panel() => find
    .ancestor(
      of: find.byTooltip(_calTip),
      matching: find.byType(Material),
    )
    .first;

/// 日期行上的值（`2026年9月17日 周四`）—— 只有它是这个形状。
Finder _dateValue() => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data != null &&
          RegExp(r'^\d{4}年\d{1,2}月\d{1,2}日 周.$').hasMatch(w.data!),
      description: '日期行的值',
    );

/// 时间行上的值（`11:08`）。
Finder _timeValue() => find.byWidgetPredicate(
      (w) =>
          w is Text && w.data != null && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data!),
      description: '时间行的值',
    );

void main() {
  testWidgets('面板里不再有键盘输入：数字框与「年 / 月 / 日 / 时 / 分」注脚一起消失',
      (tester) async {
    await _pumpEdit(tester);

    // 面板内部一个可输入的控件都没有（页面上的标题 / 内容输入框不在这个面板里）
    expect(
      find.descendant(of: _panel(), matching: find.byType(TextField)),
      findsNothing,
      reason: '日期 / 时间只能通过日历、时钟入口改',
    );

    // 数字框后面那一批单位注脚是独立 Text，应该随数字框一起消失；
    // 日期值「2026年9月17日 周四」是一整串，不会被 find.text('年') 命中。
    for (final unit in <String>['年', '月', '日', '时', '分']) {
      expect(find.text(unit), findsNothing, reason: '单位注脚「$unit」应该一起删掉');
    }

    // 更早那版的结构也不要回来
    expect(find.text('或'), findsNothing, reason: '不再有「或」分隔线');
    expect(find.text('直接输入'), findsNothing, reason: '不再给键盘输入编号');
    expect(find.text('用日历、时钟选择'), findsNothing, reason: '不再给图形选择编号');
    expect(find.textContaining('习惯图形化操作时点这里'), findsNothing);
  });

  testWidgets('面板几何：日期在上、时间在下，两个按钮右对齐成一列', (tester) async {
    await _pumpEdit(tester);

    final date = tester.getRect(_dateValue());
    final time = tester.getRect(_timeValue());
    final cal = tester.getRect(find.byTooltip(_calTip));
    final clock = tester.getRect(find.byTooltip(_clockTip));
    final panel = tester.getRect(_panel());

    // 日期一行、时间一行，时间在下一行
    expect(time.top, greaterThan(date.bottom), reason: '时间行在日期行下面');

    // 按钮与各自那一行齐平
    expect(cal.center.dy, closeTo(date.center.dy, 1), reason: '日历挂在日期行');
    expect(clock.center.dy, closeTo(time.center.dy, 1), reason: '时钟挂在时间行');

    // 按钮右边缘对齐成一列，且都在值的右边
    expect(cal.right, closeTo(clock.right, 0.01));
    expect(cal.left, greaterThan(date.right));
    expect(clock.left, greaterThan(time.right));

    // 四个元素都在面板内部
    for (final rect in <Rect>[date, time, cal, clock]) {
      expect(panel.contains(rect.center), isTrue, reason: '应该都落在面板里');
    }
  });

  testWidgets('日历入口：选完日期，日期行的值当场跟着变', (tester) async {
    await _pumpEdit(tester);
    final before = tester.widget<Text>(_dateValue()).data;

    await tester.tap(find.byTooltip(_calTip));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    // 注意 `_pickDate` 传了 `lastDate: 今天`，日历里**今天之后的格子是禁用的**
    // （点了没反应），所以这里挑「昨天」，它在任何一天都是可选的。
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 1));
    if (today.day > 1) {
      await tester.tap(find.text('${yesterday.day}'));
    } else {
      // 今天是 1 号：昨天落在上个月，先翻页（上个月最后一天一定可选）
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${yesterday.day}'));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsNothing);
    final after = tester.widget<Text>(_dateValue()).data;
    expect(after, isNot(before), reason: '值要跟着日历的选择变');
    expect(after, contains('${yesterday.year}年'));
    expect(after, contains('${yesterday.month}月${yesterday.day}日'));
  });

  testWidgets('时钟入口：弹层能打开，且用的是主题里的选择器', (tester) async {
    await _pumpEdit(tester);
    final before = tester.widget<Text>(_timeValue()).data;

    await tester.tap(find.byTooltip(_clockTip));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    // 取消不该改动任何东西
    expect(tester.widget<Text>(_timeValue()).data, before);
  });

  testWidgets('整行可点：点文字也能唤起选择器（按钮只是「这里能点」的锚点）',
      (tester) async {
    await _pumpEdit(tester);

    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);

    await tester.tap(find.text('时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
  });
}
