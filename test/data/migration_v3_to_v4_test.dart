// v3 → v4 迁移：新增 undo_entries 表。
//
// 这一步是纯新增表、不动 records，风险本来就低。但「新增表」写错的表现是
// **打开 App 直接崩**（表不存在），代价很高，所以还是钉一遍。
//
// 做法与 v2 → v3 那个测试一致：先用当前 schema 建库，再把 undo_entries 删掉、
// user_version 退回 3，重新打开时 drift 就会走 onUpgrade(3, 4)。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vestige_migration_v4');
    dbFile = File('${dir.path}/vestige.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一个 v3 形态的库：没有 undo_entries，user_version = 3，并塞一条记录。
  Future<void> seedAsV3() async {
    final db = VestigeDatabase(NativeDatabase(dbFile));
    await db.customStatement('DROP TABLE IF EXISTS undo_entries');
    await db.customStatement('PRAGMA user_version = 3');
    await db.customStatement(
      "INSERT INTO records "
      "(id, content, tags, recorded_at, created_at, updated_at, deleted) "
      "VALUES ('r1', '老的记录', '[]', 1000000, 1000000, 1000000, 0)",
    );
    await db.close();
  }

  test('迁移后 undo_entries 表存在，且既有记录不受影响', () async {
    await seedAsV3();

    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // 表能被查（不存在的话这里会抛）
    final rows = await db.customSelect('SELECT COUNT(*) AS n FROM undo_entries').get();
    expect(rows.single.data['n'], 0);

    // 老记录还在
    final records =
        await db.customSelect('SELECT id, content FROM records').get();
    expect(records.length, 1);
    expect(records.single.data['content'], '老的记录');
  });

  test('迁移后 schema 版本升到当前版本（含 v6 的 duration_s）', () async {
    await seedAsV3();
    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.first, 6);
  });
}
