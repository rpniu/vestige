import 'package:drift/drift.dart';

/// 可撤销操作的历史（保留最近若干步）。
///
/// 每行 = 一次操作 + 它**操作前**受影响记录的完整快照
/// （编解码见 `domain/record_snapshot.dart`）。
///
/// 为什么要落库、而不是只放内存：最痛的场景恰恰是「当时没反应过来」——
/// 昨天清空了回收站，今天才发现。只在内存里的话，关掉 App 就再也救不回来了。
@DataClassName('UndoEntryEntity')
class UndoEntries extends Table {
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

  /// 快照里的记录条数。
  ///
  /// **冗余存一份**是刻意的：历史列表每行都要显示「影响 N 条」，
  /// 不该为了一个数字把每一行的 JSON 都解析一遍。
  IntColumn get recordCount => integer()();
}
