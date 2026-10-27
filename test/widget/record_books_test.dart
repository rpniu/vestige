// 记录本界面（记录本页 / 「我的」入口 / 首页标识条）的回归测试。
//
// v7 起记录本存在数据库里（`record_books` 表），所以这一组测试接**真实的内存库**，
// 而不是只塞偏好存储 —— 只有真库才能验证「新建一行 → 列表多一本」
// 「删一行 → 外键级联清记录」这些行为。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/record_book.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/screens/profile_screen.dart';
import 'package:vestige/presentation/screens/record_books_screen.dart';

void main() {
  late VestigeDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    db = VestigeDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() => db.close());

  /// drift 的流会排一个零延迟定时器；换掉整棵树让它跑掉，否则报
  /// 「A Timer is still pending」。必须放在测试体末尾（不是 addTearDown）。
  Future<void> drainStreamTeardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    String? activeBookId,
    String activeBookName = kDefaultBookName,
    int bookCount = 1,
  }) async {
    // 首页 /「我的」读的是偏好缓存（不碰数据库），所以这里把缓存一起准备好
    if (activeBookId != null) {
      await prefs.setString('record_books_active', activeBookId);
      await prefs.setString('record_books_active_name', activeBookName);
      await prefs.setInt('record_books_count', bookCount);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
        ],
        child: MaterialApp(home: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addBook(String id, String name) => db.into(db.recordBooks).insert(
        RecordBookEntity(
          id: id,
          name: name,
          createdAt: DateTime(2026, 10, 1),
        ),
      );

  group('记录本页 · 初始态', () {
    testWidgets('默认记录本被自动建出来，且是当前使用的那本', (tester) async {
      await pump(tester, const RecordBooksScreen());

      expect(find.text(kDefaultBookName), findsOneWidget);
      expect(find.text('当前使用'), findsOneWidget);

      await drainStreamTeardown(tester);
    });

    testWidgets('默认记录本的删除按钮被禁用，并说明原因', (tester) async {
      await pump(tester, const RecordBooksScreen());

      expect(find.byTooltip('默认记录本不可删除'), findsOneWidget);

      await drainStreamTeardown(tester);
    });
  });

  group('记录本页 · 新建', () {
    testWidgets('输入名字 → 列表出现新记录本，当前仍是原来那本', (tester) async {
      await pump(tester, const RecordBooksScreen());

      await tester.tap(find.text('新建记录本'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '工作');
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(find.text('工作'), findsOneWidget);
      // 新建不自动切过去：当前仍是默认那本
      expect(find.text('当前使用'), findsOneWidget);
      // 真的进库了
      final rows = await db.customSelect('SELECT name FROM record_books').get();
      expect(rows.map((r) => r.data['name']), contains('工作'));

      await drainStreamTeardown(tester);
    });

    testWidgets('重名不会建出第二本', (tester) async {
      await pump(tester, const RecordBooksScreen());

      await tester.tap(find.text('新建记录本'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), kDefaultBookName);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(find.text('已有同名记录本，或名字不可用'), findsOneWidget);
      final rows =
          await db.customSelect('SELECT COUNT(*) AS n FROM record_books').get();
      expect(rows.single.data['n'], 1);

      await drainStreamTeardown(tester);
    });
  });

  group('记录本页 · 切换', () {
    testWidgets('点非当前行 → 勾标移过去，active id 落盘', (tester) async {
      await addBook('work', '工作');
      await pump(tester, const RecordBooksScreen());

      expect(find.text('当前使用'), findsOneWidget);

      await tester.tap(find.text('工作'));
      await tester.pumpAndSettle();

      expect(find.text('已切换到「工作」'), findsOneWidget);
      expect(prefs.getString('record_books_active'), 'work');
      expect(find.byTooltip('正在使用，请先切换到其它记录本'), findsOneWidget);

      await drainStreamTeardown(tester);
    });
  });

  group('记录本页 · 删除', () {
    testWidgets('删除非当前记录本要二次确认，确认后连它的记录一起消失', (tester) async {
      await addBook('work', '工作');
      await db.into(db.records).insert(
            RecordEntity(
              bookId: 'work',
              id: 'w1',
              content: '工作的一条',
              tags: const <String>[],
              recordedAt: DateTime(2026, 10, 1),
              createdAt: DateTime(2026, 10, 1),
              updatedAt: DateTime(2026, 10, 1),
              deleted: false,
            ),
          );
      await pump(tester, const RecordBooksScreen());

      await tester.tap(find.byTooltip('删除这一本'));
      await tester.pumpAndSettle();
      expect(find.text('删除「工作」？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(find.text('工作'), findsNothing);
      final books = await db.customSelect('SELECT id FROM record_books').get();
      expect(books.map((r) => r.data['id']), <Object?>[kDefaultBookId]);
      final records = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM records WHERE book_id = 'work'",
          )
          .get();
      expect(records.single.data['n'], 0, reason: '外键级联应把它的记录删掉');

      await drainStreamTeardown(tester);
    });

    testWidgets('取消确认则记录本保持不变', (tester) async {
      await addBook('work', '工作');
      await pump(tester, const RecordBooksScreen());

      await tester.tap(find.byTooltip('删除这一本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('工作'), findsOneWidget);

      await drainStreamTeardown(tester);
    });
  });

  group('「我的」页入口', () {
    testWidgets('显示当前记录本名字与总本数', (tester) async {
      await addBook('work', '工作');
      await pump(
        tester,
        const ProfileScreen(),
        activeBookId: 'work',
        activeBookName: '工作',
        bookCount: 2,
      );

      await tester.scrollUntilVisible(
        find.text('记录本'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('工作'), findsOneWidget);
      expect(find.text('共 2 个记录本 · 点此切换'), findsOneWidget);

      // 首页 AppBar 的回收站图标撤了，但「我的」页这个入口必须在
      await tester.scrollUntilVisible(
        find.text('回收站'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('回收站'), findsOneWidget);

      await drainStreamTeardown(tester);
    });
  });

  /// 打开「切换记录本」弹层：入口现在是 AppBar 的 ⋮ 菜单里的一项。
  Future<void> openBookSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换记录本'));
    await tester.pumpAndSettle();
  }

  group('首页 · 快捷切换按钮', () {
    testWidgets('入口常驻在展开菜单里（只有一本时也在，用来新建第二本）', (tester) async {
      await pump(tester, const HomeScreen());

      // 展开前：AppBar 只有一个 ⋮
      expect(find.byTooltip('更多'), findsOneWidget);

      await openBookSheet(tester);
      // 只有一本时也挂着，底部有「新建记录本」
      expect(find.text(kDefaultBookName), findsOneWidget);
      expect(find.text('新建记录本'), findsOneWidget);

      await drainStreamTeardown(tester);
    });

    testWidgets('弹层里能直接新建记录本（不离开弹层）', (tester) async {
      await pump(tester, const HomeScreen());

      await openBookSheet(tester);
      await tester.tap(find.text('新建记录本').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '工作');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '新建'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      // 建完不自动切过去，提示里点名「点它即可切换」
      expect(find.text('已新建「工作」，点它即可切换'), findsOneWidget);
      expect(
        prefs.getString('record_books_active'),
        kDefaultBookId,
        reason: '新建不自动切过去',
      );
      expect(prefs.getInt('record_books_count'), 2, reason: '缓存里的总数要跟上');
      // 新本已进入弹层列表
      expect(find.text('工作'), findsOneWidget);

      await drainStreamTeardown(tester);
    });

    testWidgets('多本时出现按钮，点开弹层选中另一本即完成切换', (tester) async {
      await addBook('work', '工作');
      await pump(
        tester,
        const HomeScreen(),
        activeBookId: kDefaultBookId,
        bookCount: 2,
      );

      await openBookSheet(tester);
      expect(find.text('切换记录本'), findsOneWidget, reason: '弹层标题');
      expect(find.text('工作'), findsOneWidget);

      await tester.tap(find.text('工作'));
      // 切换要跨一次数据库往返：drift 的 executor 走真实事件循环，
      // 假异步的 pumpAndSettle 覆盖不到，用 runAsync 放它跑完
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      // 弹层关闭（用 Dialog 类型判断：切换后首页标识条上也有「切换记录本」
      // 这几个字，光靠文案会误判）+ 切换生效（缓存里的当前本变了）
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('已切换到「工作」'), findsOneWidget);
      expect(prefs.getString('record_books_active'), 'work');

      await drainStreamTeardown(tester);
    });

    testWidgets('弹层里的「管理」跳到记录本管理页', (tester) async {
      await addBook('work', '工作');
      await prefs.setInt('record_books_count', 2);
      // 这条要验证真实导航，所以接真实路由（context.push 需要 GoRouter）
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            sharedPreferencesProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
          ],
          child: MaterialApp.router(routerConfig: createRouter()),
        ),
      );
      await tester.pumpAndSettle();

      await openBookSheet(tester);
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();

      // 已经落在记录本管理页上
      expect(find.byType(RecordBooksScreen), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);

      await drainStreamTeardown(tester);
    });
  });

  group('首页标识条', () {
    testWidgets('停在默认记录本时首页不提记录本', (tester) async {
      await pump(tester, const HomeScreen());

      expect(find.textContaining('记录本：'), findsNothing);
      expect(find.text('切换记录本'), findsNothing);

      await drainStreamTeardown(tester);
    });

    testWidgets('切到其它记录本后首页挂出「记录本：X」与切换入口', (tester) async {
      await addBook('work', '工作');
      await pump(
        tester,
        const HomeScreen(),
        activeBookId: 'work',
        activeBookName: '工作',
        bookCount: 2,
      );

      expect(find.text('记录本：工作'), findsOneWidget);
      expect(find.text('切换记录本'), findsOneWidget);

      await drainStreamTeardown(tester);
    });
  });
}
