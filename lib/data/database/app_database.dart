import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'connection/connection.dart';
import 'record.dart';
import 'record_dao.dart';
import 'undo_entry.dart';

part 'app_database.g.dart';

/// 应用数据库，对应原 Kotlin 的 VestigeDatabase（Room）。
/// 平台差异（原生 SQLite / Web IndexedDB）全部藏在 connection 层。
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
@DriftDatabase(
  tables: [Records, UndoEntries],
  daos: [RecordDao],
)
class VestigeDatabase extends _$VestigeDatabase {
  /// 默认用 connection 层提供的 connect()；
  /// 也允许外部注入 executor（测试 / 预览时方便）。
  VestigeDatabase([QueryExecutor? executor]) : super(executor ?? connect());

  @override
  int get schemaVersion => 6;

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
        },
        beforeOpen: (details) async {
          // 打开外键约束（本项目暂无关联表，留作后续扩展的钩子）
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
