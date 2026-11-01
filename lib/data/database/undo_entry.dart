import 'package:drift/drift.dart';
import 'package:vestige/data/database/record_book_table.dart';
import 'package:vestige/domain/record_book.dart';

/// 可撤销操作的历史（保留最近若干步）。
///
/// 每行 = 一次操作 + 它**操作前**受影响记录的完整快照
/// （编解码见 `domain/record_snapshot.dart`）。
///
/// 为什么要落库、而不是只放内存：最痛的场景恰恰是「当时没反应过来」——
/// 昨天清空了回收站，今天才发现。只在内存里的话，关掉 App 就再也救不回来了。
@DataClassName('UndoEntryEntity')
class UndoEntries extends Table {
  /// 所属记录本，外键指向 [RecordBooks]（级联删除）。
  ///
  /// 撤销历史**必须按记录本隔离**：快照里是整行记录，跨本回滚会把这批记录
  /// 写进另一本里去 —— 那是数据污染，比「没有撤销」糟糕得多。
  ///
  /// 默认值 `default` 同样来自 v7 迁移的回填（老库的历史全归默认本）。
  TextColumn get bookId => text()
      .withDefault(const Constant(kDefaultBookId))
      .references(RecordBooks, #id, onDelete: KeyAction.cascade)();

  /// 自增主键。历史按写入顺序排，用 rowid 最省事，
  /// 也天然给出了「哪几步比某一步更新」的判据（回滚时要用）。
  IntColumn get id => integer().autoIncrement()();

  /// 给用户看的操作名，例如「移入回收站」。
  TextColumn get label => text()();

  /// 操作发生时刻（列表里显示成「3 分钟前」）。
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  /// 受影响记录的**操作前快照**，JSON。
  TextColumn get snapshot => text()();

  /// 这次操作**新插入**的记录 id，JSON 字符串数组（schema v8）。
  ///
  /// 只靠 [snapshot] 表达不了「新增」：快照是「操作前”的整行，撤销时整行写回，
  /// 天然无法描述「这一行在这次操作里才出现」。于是 CSV 导入里那些全新 id
  /// 一行都不在快照里，撤销只能还原被覆盖的记录，新导入的仍留在库里。
  ///
  /// 语义很窄，只服务一种情况：**撤销时把这一批 id 彻底删掉**。
  /// 其余操作（软删/硬删/改标签/平移日期）都不写它，默认为空数组。
  ///
  /// 存 JSON 而不是另一张关联表：撤销时只按整批 id 做一次 IN 删除，
  /// 不需要按 id 反查历史，为它多一张表不划算。
  TextColumn get insertedIds =>
      text().withDefault(const Constant('[]'))();

  /// 快照里的记录条数。
  ///
  /// **冗余存一份**是刻意的：历史列表每行都要显示「影响 N 条」，
  /// 不该为了一个数字把每一行的 JSON 都解析一遍。
  ///
  /// 对导入这类「覆盖 + 新增」混合的操作，这里记的是**两者并集**的大小
  /// （见 `RecordRepository.pushUndo`），否则纯新增的导入会显示「影响 0 条」。
  IntColumn get recordCount => integer()();
}
