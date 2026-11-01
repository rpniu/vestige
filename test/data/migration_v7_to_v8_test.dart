// v7 → v8 迁移测试。
//
// v8 只做一件事：给 undo_entries 加 inserted_ids（记「这次操作新插入了哪些行」，
// 撤销导入时据此删除）。盯住三点：
// 1. 列确实加上了（老库没有它，不补就整条撤销链路报错）；
// 2. 存量历史读出来是空数组 —— 它们本来就只描述「操作前的样子」，
//    不该因为升级而多出要删的行；
// 3. 迁移后撤销照旧可用（不是「结构对了、功能坏了」）。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/undo_dao.dart';
import 'package:vestige/data/repositories/record_repository.dart';

void main() {
  test('v7 → v8：undo_entries 补上 inserted_ids，老历史视为「没有新增」', () async {
    final dir = Directory.systemTemp.createTempSync('vestige_v8');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}/vestige.sqlite');

    // 先用当前 schema 建库、写一条记录与一步历史，再把 undo_entries
    // 「降级」成 v7 形态（没有 inserted_ids），版本号退回 7。
    final seed = VestigeDatabase(NativeDatabase(file));
    final seedRepo = RecordRepository(seed.recordDao);
    await seedRepo.addRecord(id: 'r1', content: '升级前的记录');
    await seedRepo.pushUndo(
      '移入回收站',
      await seedRepo.getRecordsByIds(<String>['r1']),
    );
    await seed.customStatement(
      'CREATE TABLE "undo_entries_v7" ('
      '"book_id" TEXT NOT NULL DEFAULT \'default\' '
      'REFERENCES "record_books" ("id") ON DELETE CASCADE, '
      '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"label" TEXT NOT NULL, '
      '"created_at" INTEGER NOT NULL, '
      '"snapshot" TEXT NOT NULL, '
      '"record_count" INTEGER NOT NULL)',
    );
    await seed.customStatement(
      'INSERT INTO "undo_entries_v7" '
      '(book_id, id, label, created_at, snapshot, record_count) '
      'SELECT book_id, id, label, created_at, snapshot, record_count '
      'FROM undo_entries',
    );
    await seed.customStatement('DROP TABLE undo_entries');
    await seed.customStatement(
      'ALTER TABLE "undo_entries_v7" RENAME TO undo_entries',
    );
    await seed.customStatement('PRAGMA user_version = 7');
    await seed.close();

    // 用正式 schema 重新打开 → 触发 onUpgrade(7, 8)
    final migrated = VestigeDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final repo = RecordRepository(migrated.recordDao);

    final columns = await migrated
        .customSelect("SELECT name FROM pragma_table_info('undo_entries')")
        .get();
    expect(
      columns.map((row) => row.data['name']),
      contains('inserted_ids'),
      reason: 'v8 的整条撤销链路都读这一列',
    );

    final entry = (await repo.recentUndo()).single;
    expect(
      entry.insertedRecordIds,
      isEmpty,
      reason: '存量历史只描述「操作前的样子」，升级不该凭空多出要删的行',
    );

    // 迁移后功能仍可用：这一步本来的语义是「把这条记录写回」
    final outcome = await repo.undoUpTo(entry.id);
    expect(outcome.restored, 1);
    expect(outcome.removed, 0);
    expect((await repo.getRecordById('r1'))!.content, '升级前的记录');
  });
}
