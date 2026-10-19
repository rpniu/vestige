import 'package:drift/drift.dart';

import 'app_database.dart';
import 'undo_entry.dart';

part 'undo_dao.g.dart';

/// 撤销历史保留多少步。
///
/// 20 步足够覆盖「连着改错几次」；再多有两个代价：一是快照占空间
/// （一批 500 条记录 = 500 份整行 JSON），二是列表长到没人会往下翻。
const int kUndoHistoryLimit = 20;

/// 撤销历史的 DAO。
///
/// 只负责存取；「撤销一步到底要写回什么」在 `RecordRepository.undoUpTo` 里 ——
/// 那一步需要 records 表的 upsert，不属于本 DAO 的职责。
@DriftAccessor(tables: [UndoEntries])
class UndoDao extends DatabaseAccessor<VestigeDatabase> with _$UndoDaoMixin {
  UndoDao(super.db);

  /// 记一次操作。[snapshot] 是**操作前**的记录快照 JSON。
  Future<void> push({
    required String label,
    required String snapshot,
    required int recordCount,
  }) =>
      into(undoEntries).insert(
        UndoEntriesCompanion.insert(
          label: label,
          snapshot: snapshot,
          recordCount: recordCount,
        ),
      );

  /// 最近 [limit] 条，**新的在前** —— 列表直接照这个顺序渲染。
  Future<List<UndoEntryEntity>> recent({int limit = kUndoHistoryLimit}) =>
      (select(undoEntries)
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(limit))
          .get();

  /// 取一条。
  Future<UndoEntryEntity?> byId(int id) =>
      (select(undoEntries)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 删掉 id **大于等于** [id] 的全部条目。
  ///
  /// 注意方向：撤销到某一步时，要清掉的是**那一步以及比它更新的** ——
  /// 它们描述的是「已经被回滚掉、不再存在的过去」。
  Future<int> deleteFrom(int id) =>
      (delete(undoEntries)..where((t) => t.id.isBiggerOrEqualValue(id))).go();

  /// 删除**单条**历史（UI 上每行的删除按钮用）。
  ///
  /// 与 trim/条数上限是同一原则：删历史 ≠ 删数据，只抹掉「回退到这一步
  /// 之前」的能力。为什么安全：`undoUpTo` 对一批步骤取每条记录**最旧**的
  /// 快照写回，删掉中间某一步不会让更早的回退结果变味，
  /// 仅仅是「无法再退到那一步之前」。
  Future<int> deleteById(int id) =>
      (delete(undoEntries)..where((t) => t.id.equals(id))).go();

  /// 只保留最近 [keep] 条，更旧的删掉。
  Future<void> trim({int keep = kUndoHistoryLimit}) async {
    final kept = await recent(limit: keep);
    if (kept.length < keep) return; // 还没到上限
    final oldestKeptId = kept.last.id;
    await (delete(undoEntries)
          ..where((t) => t.id.isSmallerThanValue(oldestKeptId)))
        .go();
  }

  /// 清空历史。
  Future<int> clear() => delete(undoEntries).go();
}
