// v2 → v3 迁移的回归测试。
//
// v3 给 records 加了 deleted_at（记录删除时刻，恢复时清回 null）。这是本次改动里**唯一会动
// 用户既有数据**的一步：迁移写错 = 记录丢失或库打不开。所以单独钉一遍，
// 而不是靠人工在模拟器上点一次。
//
// 做法：先用当前的 schema 建库，再把 deleted_at 删掉、user_version 退回 2、
// 塞两条数据 —— 这就得到一个「v2 形态」的库。然后重新打开它，
// drift 看到 2 < 3 就会走 onUpgrade，正是线上用户升级时会发生的事。

import 'dart:io';

// drift 也导出了一个叫 `isNull` 的 SQL 表达式，和 matcher 的同名断言撞车 ——
// 这里只需要 drift 的 QueryRow / NativeDatabase，把那个符号藏掉。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';

void main() {
  late Directory dir;
  late File dbFile;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vestige_migration');
    dbFile = File('${dir.path}/vestige.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一个 v2 形态的库，并塞两条记录（一条在库里、一条在回收站）。
  Future<void> seedAsV2() async {
    final db = VestigeDatabase(NativeDatabase(dbFile));

    await db.customStatement('ALTER TABLE records DROP COLUMN deleted_at');
    await db.customStatement('PRAGMA user_version = 2');
    // 时间戳直接写 Unix 秒（drift 的存法），免得还要换算
    await db.customStatement(
      "INSERT INTO records "
      "(id, content, tags, recorded_at, created_at, updated_at, deleted) "
      "VALUES ('alive', '还活着的', '[]', 1000000, 1000000, 1000000, 0)",
    );
    await db.customStatement(
      "INSERT INTO records "
      "(id, content, tags, recorded_at, created_at, updated_at, deleted) "
      "VALUES ('gone', '在回收站的', '[]', 2000000, 2000000, 2000000, 1)",
    );
    await db.close();
  }

  /// 重新打开 = 触发迁移。
  Future<List<QueryRow>> reopenAndRead() async {
    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    return db
        .customSelect(
          'SELECT id, content, deleted, deleted_at FROM records ORDER BY id',
        )
        .get();
  }

  test('迁移后数据一条不少，内容原样', () async {
    await seedAsV2();
    final rows = await reopenAndRead();

    expect(rows.length, 2, reason: '迁移不该丢记录');
    expect(
      rows.map((QueryRow r) => r.data['content']).toList(),
      <String>['还活着的', '在回收站的'],
    );
  });

  test('deleted_at 列补上了，且软删的那条被回填了删除时间', () async {
    await seedAsV2();
    final rows = await reopenAndRead();

    final gone = rows.firstWhere((QueryRow r) => r.data['id'] == 'gone');
    expect(gone.data['deleted'], 1);
    expect(
      gone.data['deleted_at'],
      2000000,
      reason: '老数据没有真正的删除时刻，用 updated_at 兜底（尽力而为）',
    );
  });

  test('没软删的记录 deleted_at 保持 null', () async {
    await seedAsV2();
    final rows = await reopenAndRead();

    final alive = rows.firstWhere((QueryRow r) => r.data['id'] == 'alive');
    expect(alive.data['deleted'], 0);
    expect(alive.data['deleted_at'], isNull);
  });

  test('迁移后 schema 版本升到当前版本', () async {
    await seedAsV2();
    final db = VestigeDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    // 每次加迁移都要跟着改这个数字 —— 这正是它的用处：
    // 提醒你「改 schema 了」，而不是让断言悄悄跟着飘。
    expect(version.data.values.first, 4);
  });
}
