import 'package:drift/drift.dart';
import 'package:vestige/domain/record_book.dart';

import 'app_database.dart';
import 'undo_entry.dart';

part 'undo_dao.g.dart';

/// 撤销历史保留多少步。
///
/// 20 步足够覆盖「连着改错几次」；再多有两个代价：一是快照占空间
/// （一批 500 条记录 = 500 份整行 JSON），二是列表长到没人会往下翻。
/// 上限是**按记录本各算各的**（每本的 20 步），与「历史跟着数据走」一致。
const int kUndoHistoryLimit = 20;

/// 撤销历史的 DAO。
///
/// 只负责存取；「撤销一步到底要写回什么」在 `RecordRepository.undoUpTo` 里 ——
/// 那一步需要 records 表的 upsert，不属于本 DAO 的职责。
///
/// ## 记录本隔离（v7）
/// 与 `RecordDao` 一样绑定单个记录本。这**不是可选项**：撤销的动作是
/// 「把快照整行写回记录表」，如果历史和记录属于不同的本，一次撤销会把
/// 另一本的记录写进当前本（或者写回一个不存在的 id）。
@DriftAccessor(tables: [UndoEntries])
class UndoDao extends DatabaseAccessor<VestigeDatabase> with _$UndoDaoMixin {
  UndoDao(super.db, {this.bookId = kDefaultBookId});

  /// 本 DAO 负责的记录本。
  final String bookId;

  Expression<bool> get _inBook => undoEntries.bookId.equals(bookId);

  /// 记一次操作。[snapshot] 是**操作前**的记录快照 JSON。
  ///
  /// 返回新条目的 rowid —— 调用方据此精确撤销「刚做的这一步」，
  /// 不必假设「历史里最新的一定是我」（见 RecordActions.lastUndoEntryId）。
  Future<int> push({
    required String label,
    required String snapshot,
    required int recordCount,
  }) =>
      into(undoEntries).insert(
        UndoEntriesCompanion.insert(
          label: label,
          snapshot: snapshot,
          recordCount: recordCount,
          bookId: Value(bookId),
        ),
      );

  /// 最近 [limit] 条，**新的在前** —— 列表直接照这个顺序渲染。
  Future<List<UndoEntryEntity>> recent({int limit = kUndoHistoryLimit}) =>
      (select(undoEntries)
            ..where((t) => _inBook)
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(limit))
          .get();

  /// 取一条。
  Future<UndoEntryEntity?> byId(int id) =>
      (select(undoEntries)..where((t) => t.id.equals(id) & _inBook))
          .getSingleOrNull();

  /// 删掉 id **大于等于** [id] 的全部条目。
  ///
  /// 注意方向：撤销到某一步时，要清掉的是**那一步以及比它更新的** ——
  /// 它们描述的是「已经被回滚掉、不再存在的过去」。
  Future<int> deleteFrom(int id) =>
      (delete(undoEntries)
            ..where((t) => t.id.isBiggerOrEqualValue(id) & _inBook))
          .go();

  /// 删除**单条**历史（UI 上每行的删除按钮用）。
  ///
  /// 与 trim/条数上限是同一原则：删历史 ≠ 删数据，只抹掉「回退到这一步
  /// 之前」的能力。为什么安全：`undoUpTo` 对一批步骤取每条记录**最旧**的
  /// 快照写回，删掉中间某一步不会让更早的回退结果变味，
  /// 仅仅是「无法再退到那一步之前」。
  Future<int> deleteById(int id) =>
      (delete(undoEntries)..where((t) => t.id.equals(id) & _inBook)).go();

  /// 只保留最近 [keep] 条，更旧的删掉。
  Future<void> trim({int keep = kUndoHistoryLimit}) async {
    final kept = await recent(limit: keep);
    if (kept.length < keep) return; // 还没到上限
    final oldestKeptId = kept.last.id;
    await (delete(undoEntries)
          ..where((t) => t.id.isSmallerThanValue(oldestKeptId) & _inBook))
        .go();
  }

  /// 清空历史。
  Future<int> clear() => (delete(undoEntries)..where((t) => _inBook)).go();
}
