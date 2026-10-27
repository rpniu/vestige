import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:vestige/domain/record_book.dart';

import 'connection/native.dart';
import 'record.dart';
import 'record_book_table.dart';
import 'record_dao.dart';
import 'undo_entry.dart';

part 'app_database.g.dart';

/// 应用数据库，对应原 Kotlin 的 VestigeDatabase（Room）。
///
/// 目标平台只有原生（Android / iOS / Windows / macOS / Linux）。Web 目标于
/// 2026-10-27 移除 —— 它需要 `drift/wasm` 而不是 `drift/web` 才能跑，
/// 而 `drift/web` 已被上游弃用；与其维护一条编译不过的路径，不如明确不支持。
///
/// ## 版本历史
/// - v1：单时间戳 createdAt。
/// - v2：拆出 recordedAt（业务日期，可改、可回填/补记）。
///   升级时把既有记录的 recorded_at 直接回填成 created_at，
///   等价于「旧数据全部按它当时的时间算，不判定为补记」。
/// - v3：加 deletedAt（进回收站的时刻），供回收站保留期判断。
///   升级时用 updated_at 给既有软删记录回填 —— 这只是**尽力而为的估算**
///   （updatedAt 早于真正的删除时刻）。之所以可以接受：保留期只用来**提示**、
///   不自动删，估偏了最多是多提示一次，不会替用户删掉东西。
/// - v4：加 undo_entries 表（可撤销操作的历史 + 操作前快照）。
///   纯新增表，不动 records，升级无数据风险。
/// - v5：records 加 duration_min（本次记录的时长，分钟，可空）。
///   可空列裸 SQL 加即可，不需要默认值；旧行自然是 null = 没记时长。
/// - v6：时长单位从分钟改成秒 —— 加 duration_s，把 duration_min ×60 搬进去。
///   duration_min 列**留在表里不再使用**（SQLite DROP COLUMN 在老引擎上
///   不可靠，不值得为删一列冒迁移风险）；新读写只认 duration_s。
/// - v7：记录本（多数据空间）。新增 record_books 表；records / undo_entries
///   各加 book_id（外键 → record_books.id，ON DELETE CASCADE），
///   既有行一律回填 `default`（= 升级前那批数据归入默认记录本）。
///   两条外键都要「新列 + 约束」同时生效，而 SQLite **不允许**
///   `ALTER TABLE ... ADD COLUMN ... REFERENCES`（除非默认值为 NULL），
///   所以这两张表在升级路径上是**重建**的：建新表 → 拷数据 → 丢旧表 → 改名 → 补索引。
@DriftDatabase(
  tables: [Records, UndoEntries, RecordBooks],
  daos: [RecordDao],
)
class VestigeDatabase extends _$VestigeDatabase {
  /// 默认用 connection 层提供的 connect()；
  /// 也允许外部注入 executor（测试 / 预览时方便）。
  VestigeDatabase([QueryExecutor? executor]) : super(executor ?? connect());

  /// 当前 schema 版本（公开常量，便于测试与排查直接引用，
  /// 不必每次升版都去改断言里的字面量）。
  static const int currentSchemaVersion = 7;

  @override
  int get schemaVersion => currentSchemaVersion;

  /// 表里是否已有某一列。
  ///
  /// 迁移必须**幂等**：库文件可能处于「列已经在、user_version 却没跟上」的
  /// 中间态（升级中途被打断、调试时手工改过库等）。无条件 ALTER 加一列
  /// 已存在的列会抛 duplicate column —— 迁移每次打开都失败，数据库从此
  /// 打不开，所有查询静默报错，用户看到的是空列表，还以为数据丢了。
  /// （2026-09-24 在模拟器上实际出现过：user_version=2 但 v3/v4 的列全在。）
  ///
  /// `PRAGMA table_info` 的表名不能走参数绑定；table 是本文件内的字面常量，
  /// 无注入面。用表值函数 `pragma_table_info(...)` 而不是 PRAGMA 语句：
  /// 它是**标准 SELECT**，customSelect 的语义对它没有歧义。
  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect(
      "SELECT name FROM pragma_table_info('$table')",
    ).get();
    return rows.any((row) => row.data['name'] == column);
  }

  /// 库里是否已有某张表。
  Future<bool> _tableExists(String name) async {
    final row = await customSelect(
      "SELECT COUNT(*) AS n FROM sqlite_master "
      "WHERE type = 'table' AND name = '$name'",
    ).getSingle();
    return (row.data['n'] as int) > 0;
  }

  /// 建库 / 升级的迁移逻辑。
  ///
  /// 每一步都先探测现状再动手（见 [_columnExists] 的说明）——
  /// 对「结构已经是新版、只有版本号滞后」的库，各步自然跳过，
  /// 等价于把版本号补齐，用户数据原样可读。
  ///
  /// **降级也走这里**（2026-10-27 审查 M-008 的核实结论）：drift 的
  /// `OpeningDetails.hadUpgrade` 定义是 `versionBefore != versionNow`，
  /// 降级时它同样调用本方法，只是 `from > to`。而下面每一步都以 `from < N`
  /// 为条件，于是全部跳过 —— 结构保持原样、版本号被写回旧值，数据可继续读。
  /// 这正是想要的行为，不需要（drift 也没有）单独的 `onDowngrade` 钩子。
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2 && !await _columnExists('records', 'recorded_at')) {
            // 用裸 SQL 加列：drift 的 addColumn 无法给「NOT NULL 且只有
            // Dart 端 clientDefault」的列提供 SQL 默认值，裸 SQL 更直接。
            // drift 默认把 dateTime 存成 Unix 秒（INTEGER），故可直接复制。
            await customStatement(
              'ALTER TABLE records ADD COLUMN recorded_at INTEGER NOT NULL DEFAULT 0',
            );
            await customStatement(
              'UPDATE records SET recorded_at = created_at WHERE recorded_at = 0',
            );
          }
          if (from < 2) {
            // 索引创建天然幂等（IF NOT EXISTS），放在列探测外：
            // 「列已在但索引没建」的中间态也能补齐。
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_recorded_at ON records (recorded_at)',
            );
          }
          if (from < 3 && !await _columnExists('records', 'deleted_at')) {
            // 可空列，裸 SQL 加即可（与 v2 的 recorded_at 不同，这个不需要默认值）。
            await customStatement(
              'ALTER TABLE records ADD COLUMN deleted_at INTEGER',
            );
            // 既有软删记录没有真正的删除时刻，用最后修改时间兜底 —— 尽力而为，
            // 因为这一列只做记录，不参与任何自动删除判定。
            await customStatement(
              'UPDATE records SET deleted_at = updated_at WHERE deleted = 1',
            );
          }
          if (from < 3) {
            // `idx_deleted` 建在 deleted 列上，随 v3 引入。它由 `createAll()`
            // 在**全新安装**时创建，但历史上从没写进 onUpgrade —— 结果是从
            // v1/v2 升级上来的老库一直缺这个索引，回收站查询走全表扫描。
            // 索引创建天然幂等（IF NOT EXISTS），放在列探测外补上。
            await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_deleted ON records (deleted)',
            );
          }
          if (from < 4 && !await _tableExists('undo_entries')) {
            // 纯新增一张表，不碰 records —— 这一步没有数据风险。
            await m.createTable(undoEntries);
          }
          if (from < 5 && !await _columnExists('records', 'duration_min')) {
            // 可空列，裸 SQL 加即可（同 v3 的 deleted_at，不需要默认值）。
            await customStatement(
              'ALTER TABLE records ADD COLUMN duration_min INTEGER',
            );
          }
          if (from < 6 && !await _columnExists('records', 'duration_s')) {
            // 时长单位分钟 → 秒：新列加上后，把旧分钟列的值 ×60 搬过来。
            // duration_min 列保留不删（见版本历史 v6 的说明）。
            await customStatement(
              'ALTER TABLE records ADD COLUMN duration_s INTEGER',
            );
            await customStatement(
              'UPDATE records SET duration_s = duration_min * 60 '
              'WHERE duration_s IS NULL AND duration_min IS NOT NULL',
            );
          }
          if (from < 7) {
            await _migrateToRecordBooks();
          }
        },
        beforeOpen: (details) async {
          // 打开外键约束 —— records / undo_entries 的 book_id 指向 record_books，
          // 不打开这个 pragma，级联删除与「拒绝孤儿行」都不会生效。
          await customStatement('PRAGMA foreign_keys = ON');
          // 默认记录本这一行是**外键的落脚点**：没有它，任何一条
          // `book_id = default` 的写入都会被拒绝。放在这里而不是交给上层，
          // 是因为「谁先读库」不确定（首页、导入、测试都可能先碰到库）。
          // INSERT OR IGNORE：每次打开都执行，幂等。
          await customStatement(
            'INSERT OR IGNORE INTO record_books (id, name, created_at) '
            "VALUES ('$kDefaultBookId', '$kDefaultBookName', "
            "CAST(strftime('%s','now') AS INTEGER))",
          );
        },
      );

  /// v7：引入记录本表，并把既有数据归入默认记录本。
  ///
  /// 每一步都先探测再动手，因此对「结构已新、版本号滞后」的库是幂等的
  /// （同 [_columnExists] 的说明）。
  ///
  /// 为什么 `records` / `undo_entries` 在升级路径上是**重建**而不是
  /// `ALTER TABLE ADD COLUMN`：SQLite 不允许给既有表添加带 `REFERENCES`
  /// 且默认值非 NULL 的列 —— 而这里既要有 `NOT NULL DEFAULT 'default'`、
  /// 又要挂 `ON DELETE CASCADE` 外键。重建顺便把 v5 遗留的 `duration_min`
  /// 列清掉（它的数据在 v6 已搬进 `duration_s`，drift 的 schema 里也没有它）。
  Future<void> _migrateToRecordBooks() async {
    if (!await _tableExists('record_books')) {
      await customStatement(
        'CREATE TABLE "record_books" ('
        '"id" TEXT NOT NULL, '
        '"name" TEXT NOT NULL, '
        '"created_at" INTEGER NOT NULL, '
        'PRIMARY KEY ("id"))',
      );
    }
    // 默认记录本这一行必须存在：下面回填的 book_id 要指向它，否则外键不成立。
    // 时间是 drift 的存储格式（Unix 秒），交给 SQLite 自己取当前时刻。
    await customStatement(
      'INSERT OR IGNORE INTO record_books (id, name, created_at) '
      "VALUES ('$kDefaultBookId', '$kDefaultBookName', "
      "CAST(strftime('%s','now') AS INTEGER))",
    );

    if (!await _columnExists('records', 'book_id')) {
      await customStatement(
        'CREATE TABLE "records_v7" ('
        '"book_id" TEXT NOT NULL DEFAULT \'$kDefaultBookId\' '
        'REFERENCES "record_books" ("id") ON DELETE CASCADE, '
        '"id" TEXT NOT NULL, '
        '"title" TEXT NULL, '
        '"content" TEXT NOT NULL, '
        '"tags" TEXT NOT NULL, '
        '"recorded_at" INTEGER NOT NULL, '
        '"created_at" INTEGER NOT NULL, '
        '"updated_at" INTEGER NOT NULL, '
        '"deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), '
        '"deleted_at" INTEGER NULL, '
        '"duration_s" INTEGER NULL, '
        'PRIMARY KEY ("id"))',
      );
      // 列名显式写全：老库可能缺 duration_s（v5 及更早），逐列探测比
      // 「假定结构」安全 —— 少一列总比整次升级失败（App 打不开）强。
      final columns = <String>[
        if (await _columnExists('records', 'title')) 'title',
        'content',
        if (await _columnExists('records', 'tags')) 'tags',
        if (await _columnExists('records', 'recorded_at')) 'recorded_at',
        'created_at',
        if (await _columnExists('records', 'updated_at')) 'updated_at',
        if (await _columnExists('records', 'deleted')) 'deleted',
        if (await _columnExists('records', 'deleted_at')) 'deleted_at',
        if (await _columnExists('records', 'duration_s')) 'duration_s',
      ];
      await customStatement(
        'INSERT INTO "records_v7" (book_id, id, ${columns.join(', ')}) '
        "SELECT '$kDefaultBookId', id, ${columns.join(', ')} FROM records",
      );
      await customStatement('DROP TABLE records');
      await customStatement('ALTER TABLE "records_v7" RENAME TO records');
    }
    // 索引随旧表一起没了（DROP TABLE 会删掉它的索引），这里统一补回。
    // 全新安装的索引由 createAll() 建，语句相同，IF NOT EXISTS 两边都安全。
    for (final sql in <String>[
      'CREATE INDEX IF NOT EXISTS idx_recorded_at ON records (recorded_at)',
      'CREATE INDEX IF NOT EXISTS idx_deleted ON records (deleted)',
      'CREATE INDEX IF NOT EXISTS idx_book_recorded_at '
          'ON records (book_id, recorded_at)',
    ]) {
      await customStatement(sql);
    }

    if (!await _columnExists('undo_entries', 'book_id')) {
      await customStatement(
        'CREATE TABLE "undo_entries_v7" ('
        '"book_id" TEXT NOT NULL DEFAULT \'$kDefaultBookId\' '
        'REFERENCES "record_books" ("id") ON DELETE CASCADE, '
        '"id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
        '"label" TEXT NOT NULL, '
        '"created_at" INTEGER NOT NULL, '
        '"snapshot" TEXT NOT NULL, '
        '"record_count" INTEGER NOT NULL)',
      );
      await customStatement(
        'INSERT INTO "undo_entries_v7" '
        '(book_id, id, label, created_at, snapshot, record_count) '
        "SELECT '$kDefaultBookId', id, label, created_at, snapshot, record_count "
        'FROM undo_entries',
      );
      await customStatement('DROP TABLE undo_entries');
      await customStatement(
        'ALTER TABLE "undo_entries_v7" RENAME TO undo_entries',
      );
    }
  }
}
