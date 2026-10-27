// 记录本（多数据空间）的存储层回归测试。
//
// 结构是「一个库 + 两张表 + 一条外键」：
// ```
// record_books(id) ←── book_id ── records
//                  ←── book_id ── undo_entries
// ```
// 这个文件钉住四件事：
// 1. 隔离：两本各写各的，`getAllActiveRecordsSync` 只看得到自己那本；
// 2. 级联：删掉一条记录本，它的记录与撤销历史一起消失（不靠手写 SQL）；
// 3. 迁移：v6 老库打开后，既有记录全部归入默认记录本、外键确实生效；
// 4. 撤销历史不跨本：历史跟着记录本走。

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/book_dao.dart';
import 'package:vestige/data/database/record_dao.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/domain/record_book.dart';

void main() {
  late VestigeDatabase db;
  late BookDao books;

  setUp(() async {
    db = VestigeDatabase(NativeDatabase.memory());
    books = BookDao(db);
    await books.ensureDefault();
  });

  tearDown(() => db.close());

  RecordRepository repoOf(String bookId) =>
      RecordRepository(RecordDao(db, bookId: bookId));

  group('隔离', () {
    test('两本各写各的，读起来互不可见', () async {
      final work = await books.create('工作');
      final mine = repoOf(kDefaultBookId);
      final theirs = repoOf(work.id);

      await mine.addRecord(content: '默认那本的一条');
      await theirs.addRecord(content: '工作那本的一条');
      await theirs.addRecord(content: '工作那本的第二条');

      expect(
        (await mine.getAllActiveRecordsSync()).map((r) => r.content),
        <String>['默认那本的一条'],
      );
      expect(
        (await theirs.getAllActiveRecordsSync()).map((r) => r.content).toSet(),
        <String>{'工作那本的一条', '工作那本的第二条'},
      );
    });

    test('按 id 取记录也被本隔离（拿别的本的 id 查不到）', () async {
      final work = await books.create('工作');
      await repoOf(work.id).addRecord(content: '工作的记录', id: 'r-work');

      expect(await repoOf(kDefaultBookId).getRecordById('r-work'), isNull);
      expect(await repoOf(work.id).getRecordById('r-work'), isNotNull);
    });

    test('搜索不会跨本', () async {
      final work = await books.create('工作');
      await repoOf(kDefaultBookId).addRecord(content: '共同的词 A');
      await repoOf(work.id).addRecord(content: '共同的词 B');

      final hits = await repoOf(work.id).searchRecords('共同的词');
      expect(hits.map((r) => r.content), <String>['共同的词 B']);
    });

    test('回收站按本隔离：删的是自己那本', () async {
      final work = await books.create('工作');
      await repoOf(kDefaultBookId).addRecord(content: '默认', id: 'd1');
      await repoOf(work.id).addRecord(content: '工作', id: 'w1');

      await repoOf(work.id).deleteRecord('w1');

      expect(await repoOf(kDefaultBookId).getDeletedRecords(), isEmpty);
      expect(
        (await repoOf(work.id).getDeletedRecords()).map((r) => r.content),
        <String>['工作'],
      );
    });
  });

  group('外键级联', () {
    test('删掉记录本 → 它的记录与撤销历史一起消失，别的不受影响', () async {
      final work = await books.create('工作');
      final mine = repoOf(kDefaultBookId);
      final theirs = repoOf(work.id);

      await mine.addRecord(content: '默认留着我', id: 'keep');
      await theirs.addRecord(content: '工作会被删', id: 'gone');
      // 显式造一条撤销历史（快照由仓储写进 undo_entries，带 book_id）
      await theirs.pushUndo(
        '移入回收站',
        await theirs.getRecordsByIds(<String>['gone']),
      );
      expect(await theirs.recentUndo(), isNotEmpty, reason: '前置：历史已写入');

      expect(await books.deleteById(work.id), 1);

      // 记录本行没了
      expect(await books.byId(work.id), isNull);
      // 它的记录与历史被级联清掉（直接查库，绕开 DAO 的 book_id 过滤）
      final leftRecords = await db.customSelect(
        'SELECT COUNT(*) AS n FROM records WHERE book_id = ?',
        variables: <Variable<Object>>[Variable<String>(work.id)],
      ).getSingle();
      expect(leftRecords.data['n'], 0);
      final leftUndo = await db.customSelect(
        'SELECT COUNT(*) AS n FROM undo_entries WHERE book_id = ?',
        variables: <Variable<Object>>[Variable<String>(work.id)],
      ).getSingle();
      expect(leftUndo.data['n'], 0);

      // 默认那本毫发无损
      expect(
        (await mine.getAllActiveRecordsSync()).map((r) => r.content),
        <String>['默认留着我'],
      );
    });

    test('指向不存在的记录本会被外键拒绝（插不进去）', () async {
      await expectLater(
        db.customStatement(
          "INSERT INTO records (book_id, id, content, tags, recorded_at, "
          "created_at, updated_at, deleted) "
          "VALUES ('no-such-book', 'r1', 'x', '[]', 1, 1, 1, 0)",
        ),
        throwsA(anything),
      );
    });
  });

  group('撤销历史按本隔离', () {
    test('历史条目属于各自的记录本', () async {
      final work = await books.create('工作');
      final mine = repoOf(kDefaultBookId);
      final theirs = repoOf(work.id);

      await mine.addRecord(content: 'A', id: 'a');
      await theirs.addRecord(content: 'B', id: 'b');
      await mine.pushUndo('移入回收站', await mine.getRecordsByIds(<String>['a']));
      await theirs.pushUndo('移入回收站', await theirs.getRecordsByIds(<String>['b']));

      final mineUndo = await mine.recentUndo();
      final theirsUndo = await theirs.recentUndo();
      expect(mineUndo, hasLength(1));
      expect(theirsUndo, hasLength(1));
      // 快照内容能区分开：各自只含自己那本的那条
      // 用 JSON 里的 content 片段比对，别用裸字母（"deletedAt" 里也有大写 A）
      expect(mineUndo.single.snapshot, contains('"content":"A"'));
      expect(theirsUndo.single.snapshot, contains('"content":"B"'));
      expect(theirsUndo.single.snapshot, isNot(contains('"content":"A"')));
    });
  });

  group('v6 → v7 迁移', () {
    test('老库的既有记录全部归入默认记录本，且默认本被建出来', () async {
      final dir = Directory.systemTemp.createTempSync('vestige_v7');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/vestige.sqlite');

      // 先用当前 schema 建库，再把它「降级」成 v6 形态：
      // 去掉 book_id 列与 record_books 表，版本号退回 6。
      final seed = VestigeDatabase(NativeDatabase(file));
      // 默认记录本那行由 beforeOpen 补好了，这里不用再插（否则 UNIQUE 冲突）
      await seed.customStatement(
        "INSERT INTO records (book_id, id, content, tags, recorded_at, "
        "created_at, updated_at, deleted, duration_s) "
        "VALUES ('default', 'old1', '升级前的记录', '[]', 1000, 1000, 1000, 0, 65)",
      );
      // SQLite 不能直接删列，重建一张 v6 形态的 records
      await seed.customStatement(
        'CREATE TABLE "records_v6" ('
        '"id" TEXT NOT NULL, "title" TEXT NULL, "content" TEXT NOT NULL, '
        '"tags" TEXT NOT NULL, "recorded_at" INTEGER NOT NULL, '
        '"created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, '
        '"deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), '
        '"deleted_at" INTEGER NULL, "duration_s" INTEGER NULL, '
        'PRIMARY KEY ("id"))',
      );
      await seed.customStatement(
        'INSERT INTO "records_v6" (id, title, content, tags, recorded_at, '
        'created_at, updated_at, deleted, deleted_at, duration_s) '
        "SELECT id, title, content, tags, recorded_at, created_at, updated_at, "
        'deleted, deleted_at, duration_s FROM records',
      );
      await seed.customStatement('DROP TABLE records');
      await seed.customStatement('ALTER TABLE "records_v6" RENAME TO records');
      await seed.customStatement('DROP TABLE record_books');
      await seed.customStatement('PRAGMA user_version = 6');
      await seed.close();

      // 用正式 schema 重新打开 → 触发 onUpgrade(6, 7)
      final migrated = VestigeDatabase(NativeDatabase(file));
      addTearDown(migrated.close);

      // 老记录还在，且 book_id 被回填成默认本
      final rows = await migrated
          .customSelect('SELECT id, content, book_id, duration_s FROM records')
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['content'], '升级前的记录');
      expect(rows.single.data['book_id'], kDefaultBookId);
      expect(rows.single.data['duration_s'], 65, reason: '时长列不能被重建弄丢');

      // 默认记录本行被补了出来
      final bookRows =
          await migrated.customSelect('SELECT id, name FROM record_books').get();
      expect(bookRows, hasLength(1));
      expect(bookRows.single.data['id'], kDefaultBookId);

      final version =
          await migrated.customSelect('PRAGMA user_version').getSingle();
      expect(
        version.data.values.first,
        VestigeDatabase.currentSchemaVersion,
      );

      // 外键生效：新增一个指向不存在记录本的记录应当失败
      await expectLater(
        migrated.customStatement(
          "INSERT INTO records (book_id, id, content, tags, recorded_at, "
          "created_at, updated_at, deleted) "
          "VALUES ('ghost', 'x', 'x', '[]', 1, 1, 1, 0)",
        ),
        throwsA(anything),
      );
    });
  });

  group('记录本的增删改', () {
    test('新建的记录本默认取名创建时刻排序，且默认本永远在列表里', () async {
      await books.create('工作');
      final all = await books.getAll();
      expect(all.first.id, kDefaultBookId);
      expect(all.map((b) => b.name), <String>[kDefaultBookName, '工作']);
    });

    test('重名检测（改名时排除自己）', () async {
      final work = await books.create('工作');
      expect(await books.nameExists('工作'), isTrue);
      expect(await books.nameExists('工作', exceptId: work.id), isFalse);
      expect(await books.nameExists('读书'), isFalse);
    });

    test('改名不影响记录归属', () async {
      final work = await books.create('工作');
      await repoOf(work.id).addRecord(content: '一条', id: 'r1');

      expect(await books.rename(work.id, '事业'), isTrue);

      expect((await books.byId(work.id))!.name, '事业');
      expect(
        (await repoOf(work.id).getAllActiveRecordsSync()).single.content,
        '一条',
      );
    });
  });
}
