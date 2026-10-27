// 「user_version 落后于真实结构」的迁移回归测试。
//
// 背景：2026-09-24 在模拟器上真实踩到 —— 库文件的表结构**已经是完整新版**
// （records 含 recorded_at / deleted_at、undo_entries 表也在），
// 但 user_version 停在 2。旧迁移代码不探测现状、无条件 ALTER 加列，
// 于是每次打开都抛 duplicate column，数据库永远打不开：
// 首页 110 条记录全部显示为空态，操作历史无限转圈。
//
// 这类库可能来自：升级中途被打断、调试时手工改过库、或工具写入时漏设版本号。
// 修复后的迁移每一步先探测列/表是否存在再动手，对这种库等价于
// 「把版本号补齐」，数据原样可读。这个文件就是钉住这个行为：
// **无论版本号落后成什么样，打开都不许炸，数据一条不许丢。**

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vestige_migration_stale');
    dbFile = File('${dir.path}/vestige.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一个「结构已是当前完整版、user_version 却停在 [version]」的库，
  /// 并塞一条记录 —— 正是模拟器上那个打不开的库的形态。
  Future<void> seedCurrentSchemaWithStaleVersion(int version) async {
    final db = VestigeDatabase(NativeDatabase(dbFile));
    await db.customStatement('PRAGMA user_version = $version');
    await db.customStatement(
      "INSERT INTO records "
      "(id, content, tags, recorded_at, created_at, updated_at, deleted) "
      "VALUES ('r1', '被困住的记录', '[\"a\"]', 1000000, 1000000, 1000000, 0)",
    );
    await db.close();
  }

  test('版本号停在 2（列全在）：打开不炸，数据可读', () async {
    await seedCurrentSchemaWithStaleVersion(2);

    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final rows =
        await db.customSelect('SELECT id, content FROM records').get();
    expect(rows.single.data['content'], '被困住的记录');
  });

  test('版本号停在 1（全结构在）：打开不炸，undo_entries 可查', () async {
    // 用 1 而不是 0：SQLite 里 user_version = 0 的语义是「还没初始化过」，
    // drift 见到 0 一律走 onCreate（createAll）—— 而 seed 出来的库结构已经
    // 全在，createAll 再建一次 `idx_deleted`（该索引没有 IF NOT EXISTS）
    // 会直接抛「index idx_deleted already exists」。
    // 换句话说「版本号 0 + 结构已全」这个组合在 drift 下构造不出来，
    // 想要表达的是「版本号远落后于真实结构」，用 1 即可（v1 是合法的最低已有版本）。
    await seedCurrentSchemaWithStaleVersion(1);

    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM undo_entries')
        .get();
    expect(rows.single.data['n'], 0);
  });

  test('打开后版本号补齐到当前版本，记录还在', () async {
    await seedCurrentSchemaWithStaleVersion(2);

    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    // 每次加迁移都要跟着改这个数字（与 v2→v3 测试同款断言）
    expect(version.data.values.first, VestigeDatabase.currentSchemaVersion);
    expect(
      (await db.customSelect('SELECT COUNT(*) AS n FROM records').get())
          .single
          .data['n'],
      1,
    );
  });

  test('undo_entries 缺失且版本号停在 3：照常补建', () async {
    // 与 stale-version 相对「表缺失」的另一半：v3 形态库上重复建表不许炸
    final db = VestigeDatabase(NativeDatabase(dbFile));
    await db.customStatement('DROP TABLE undo_entries');
    await db.customStatement('PRAGMA user_version = 3');
    await db.close();

    final reopened = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(reopened.close);

    final rows = await reopened
        .customSelect('SELECT COUNT(*) AS n FROM undo_entries')
        .get();
    expect(rows.single.data['n'], 0);
  });
}
