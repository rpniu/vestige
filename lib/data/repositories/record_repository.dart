import 'package:drift/drift.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/record_dao.dart';
import 'package:vestige/data/database/undo_dao.dart';
import 'package:vestige/domain/record_snapshot.dart';
import 'package:vestige/domain/undo_outcome.dart';

/// 仓储层：封装 DAO，对上层屏蔽存储细节（对应原 Kotlin 的 RecordRepository）。
///
/// v2 的关键约定（补记能力的数据基础）：
/// - 新增记录时 `createdAt` 永远取「现在」，不受业务日期影响；
/// - `recordedAt` 由调用方给，可以是今天，也可以是过去任意一天（补记）；
/// - 编辑既有记录时不再动 `createdAt`，避免把审计信息改坏。
class RecordRepository {
  final RecordDao _dao;

  RecordRepository(this._dao);

  // ── 读取 ────────────────────────────────────────────────────────────

  Stream<List<RecordEntity>> watchAllRecords() => _dao.watchAllActive();

  Stream<List<RecordEntity>> watchDeletedRecords() => _dao.watchDeleted();

  Future<RecordEntity?> getRecordById(String id) => _dao.getById(id);

  Future<List<RecordEntity>> getAllActiveRecordsSync() =>
      _dao.getAllActiveSync();

  /// 全文搜索（标题 / 正文 / 标签的包含匹配），按业务日期倒序。
  ///
  /// [from] / [to] 限定业务日期，**左闭右开**；关键词为空时只按日期范围查
  /// （= 浏览某段时间的全部记录）。
  Future<List<RecordEntity>> searchRecords(
    String query, {
    DateTime? from,
    DateTime? to,
  }) =>
      _dao.searchActive(query, from: from, to: to);

  // ── 写入 ────────────────────────────────────────────────────────────

  /// 新增一条记录。
  ///
  /// [recordedAt] 是这条记录「属于」的日期，可传过去的时间实现补记；
  /// 不传则默认当前时刻。`createdAt` 恒为当前时刻，由数据库 clientDefault 写入。
  /// [durationSec] 可选时长（**秒**），null = 没记时长。
  Future<void> addRecord({
    required String content,
    String? title,
    List<String> tags = const [],
    DateTime? recordedAt,
    String? id,
    int? durationSec,
  }) {
    final now = DateTime.now();
    return _dao.insert(
      RecordsCompanion.insert(
        id: id == null ? const Value.absent() : Value(id),
        content: content,
        title: Value(_nullIfBlank(title)),
        tags: tags,
        recordedAt: Value(recordedAt ?? now),
        updatedAt: Value(now),
        durationS: Value(durationSec),
      ),
    );
  }

  /// 更新一条记录。`createdAt` 保持不变（除非显式传 [createdAt]，仅 CSV 导入用）。
  ///
  /// 时长参数区分三个态：[durationSec] 非 null = 设成该值；[clearDuration] 为
  /// true = 抹掉（写 null）；两者都不给 = **不动时长**。编辑页据此精确表达
  /// 「没填」和「清空」的区别，一次 UPDATE 写完，不拆两次调用。
  Future<int> updateRecord({
    required String id,
    required String content,
    String? title,
    List<String> tags = const [],
    DateTime? recordedAt,
    DateTime? createdAt,
    int? durationSec,
    bool clearDuration = false,
  }) {
    assert(!clearDuration || durationSec == null, '设值与清空不能同时给');
    final now = DateTime.now();
    return _dao.replace(
      RecordsCompanion(
        id: Value(id),
        content: Value(content),
        title: Value(_nullIfBlank(title)),
        tags: Value(tags),
        recordedAt: recordedAt == null ? const Value.absent() : Value(recordedAt),
        createdAt: createdAt == null ? const Value.absent() : Value(createdAt),
        updatedAt: Value(now),
        durationS: clearDuration
            ? const Value(null)
            : durationSec == null
                ? const Value.absent()
                : Value(durationSec),
      ),
    );
  }

  /// 批量把一批记录的日期整体平移（多选补记用）：+1 天 / -1 天。
  ///
  /// 旧实现是「逐条 `getById` 再逐条 `updateRecordedAt`」，N 条记录 = 2N 次独立语句，
  /// 全在一个 for 循环里串行 await。现在压成 DAO 里的一条 UPDATE（见
  /// [RecordDao.shiftRecordedAt]）。语义不变：仍然是给 `recordedAt` 加上这个时长。
  Future<void> shiftRecordedAt(List<String> ids, Duration delta) =>
      _dao.shiftRecordedAt(ids, delta);

  // ── 批量标签 ────────────────────────────────────────────────────────

  /// 批量打标签 / 去标签（多选打标签用），返回**真正被改动**的条数。
  ///
  /// 与 [shiftRecordedAt] 的差别：那里每行加的是同一个增量，一条 UPDATE 就够；
  /// 这里每行要并上**自己已有的**标签，结果逐行不同，所以先读出来、在 Dart 里算，
  /// 再交给 DAO 在**一个事务**里写回 —— 不会出现「一半记录改了、另一半没改」。
  ///
  /// [add] 是并集（已有的保留、新加的补在后面），[remove] 是差集；两个都给时先加后减。
  ///
  /// 标签没变化的记录**不写库** —— 既省一次写，也避免把 `updatedAt` 无谓地推新
  /// （那个字段是回收站的排序依据，不该被一次空操作搅动）。
  Future<int> applyTags(
    List<String> ids, {
    List<String> add = const <String>[],
    List<String> remove = const <String>[],
  }) async {
    if (ids.isEmpty || (add.isEmpty && remove.isEmpty)) return 0;

    final targets = await _dao.getByIds(ids);
    final changed = <String, List<String>>{};
    for (final record in targets) {
      final next = <String>[...record.tags];
      for (final tag in add) {
        if (!next.contains(tag)) next.add(tag);
      }
      if (remove.isNotEmpty) next.removeWhere(remove.contains);
      if (!_sameTags(next, record.tags)) changed[record.id] = next;
    }

    await _dao.updateTagsMany(changed);
    return changed.length;
  }

  /// 两个标签列表是不是完全一样（顺序也要一样）。
  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── 删除 / 恢复 ─────────────────────────────────────────────────────

  Future<void> deleteRecord(String id) => _dao.softDelete(id);

  Future<void> deleteRecords(List<String> ids) => _dao.softDeleteMany(ids);

  Future<void> restoreRecord(String id) => _dao.restore(id);

  Future<void> restoreRecords(List<String> ids) => _dao.restoreMany(ids);

  Future<void> hardDeleteRecord(String id) => _dao.hardDelete(id);

  Future<void> hardDeleteRecords(List<String> ids) => _dao.hardDeleteMany(ids);

  Future<int> emptyTrash() => _dao.emptyTrash();

  // ── 撤销 ────────────────────────────────────────────────────────────

  /// 撤销历史用的 DAO。
  ///
  /// **手动构造，而不是走 `db.undoDao`** —— 这是实践中确认的 drift 行为：
  /// 只要把 `UndoDao` 写进 `@DriftDatabase(daos: [...])`，drift 就会**静默地
  /// 一个 DAO getter 都不生成**（连原有的 `recordDao` 一起消失，
  /// 全项目报 `undefined_getter`）。而 `UndoDao` 本身是没问题的
  /// （`undo_dao.g.dart` 里的 mixin 正常生成），只是不能进那个列表。
  ///
  /// 手动构造完全等价：DAO 是无状态的，只是给 db 套一层类型化的查询方法。
  ///
  /// **必须与记录 DAO 绑定同一个记录本**：撤销写回的是整行快照，
  /// 历史与记录分属不同的本会把数据写到错误的记录本里去。
  late final UndoDao _undo = UndoDao(_dao.db, bookId: _dao.bookId);

  /// 按一批 id 取整行（**存快照用**）。
  Future<List<RecordEntity>> getRecordsByIds(List<String> ids) =>
      _dao.getByIds(ids);

  /// 按一批 id 取整行，**不限记录本**（跨本导入存快照用）。
  Future<List<RecordEntity>> getRecordsByIdsAnyBook(List<String> ids) =>
      _dao.getByIdsAnyBook(ids);

  /// 指定几本的活跃记录（**多记录本导出用**）。
  Future<List<RecordEntity>> getAllActiveRecordsInBooks(List<String> bookIds) =>
      _dao.getActiveInBooks(bookIds);

  /// 回收站里的全部记录（**清空回收站前存快照用**）。
  Future<List<RecordEntity>> getDeletedRecords() => _dao.getDeletedSync();

  /// 把一组读写包进**一个事务**。
  ///
  /// 用于「业务动作 + 撤销快照」必须同生共死的场景（2026-10-27 审查 M-006）：
  /// 任何一步失败都不该留下「数据改了、历史没记」的中间态。
  Future<T> transaction<T>(Future<T> Function() action) =>
      _dao.db.transaction(action);

  /// 记一步可撤销的操作。
  ///
  /// [before] 是**操作前**的整行快照。[insertedIds] 是这次操作**新插入**的
  /// 记录 id（目前只有 CSV 导入会传）—— 它们不在 [before] 里，撤销时按它删除。
  ///
  /// 两者都为空才不记录：没有可回滚的内容，留一条无法生效的条目只会干扰列表。
  /// 注意**纯新增也要记**（schema v8 起）：只有 new id、没有覆盖的导入同样必须能撤销，
  /// 而这在 schema v8 之前表达不了（见 [undoUpTo]）。
  ///
  /// 返回新历史条目的 id；两者都为空时返回 null（表示这次操作没有产生回退点，
  /// UI 据此不挂「撤销」按钮 —— 见 RecordActions.lastUndoEntryId）。
  Future<int?> pushUndo(
    String label,
    List<RecordEntity> before, {
    List<String> insertedIds = const <String>[],
  }) async {
    if (before.isEmpty && insertedIds.isEmpty) return null;
    final id = await _undo.push(
      label: label,
      snapshot: RecordSnapshot.encode(before),
      // 「影响 N 条」= 覆盖的 + 新增的。两者不相交：同一 id 要么本来就在库里
      // （进 before），要么是新的（进 insertedIds）；跨本撞 id 的行会被换成新
      // uuid，原 id 属于别的本，本本的 before 里也不会有它。
      recordCount: before.length + insertedIds.length,
      insertedIds: insertedIds,
    );
    await _undo.trim();
    return id;
  }

  /// 最近的撤销历史（新的在前）。
  Future<List<UndoEntryEntity>> recentUndo() => _undo.recent();

  /// 删除单条撤销历史。只抹掉「回退到这一步之前」的能力，记录数据不受影响。
  Future<void> deleteUndoEntry(int entryId) => _undo.deleteById(entryId);

  /// 清空撤销历史。同上 —— 拿掉全部回退点而已。
  Future<int> clearUndoHistory() => _undo.clear();

  /// 撤销到 [entryId] **这一步之前** —— 它自己以及比它更新的步骤一起回滚。
  ///
  /// 算法：把这几步的快照按「新 → 旧」合并，同一条记录**取最旧的那份**
  /// （那才是这些操作都没发生过时的状态），再整行写回去。
  ///
  /// 另有一路**删除**（schema v8）：条目里记了「这次新插入」的 id，撤销时那批行必须
  /// 从库里消失 —— 上面那套「快照写回」只能描述「原来长什么样」，
  /// 表达不了「这一行本来不存在」。两路合起来，CSV 导入的覆盖与新增都能退。
  ///
  /// 为什么用「快照 + 整行写回」而不是「每步写一个反向操作」：
  /// - 反向操作对**并集**类语义是错的：批量加标签 #A 的反向是去掉 #A，
  ///   但某条本来就有 #A 的记录，加的时候是空操作，撤销却会把它删掉；
  /// - 「彻底删除」根本没有反向操作 —— 而快照里有完整字段，
  ///   整行写回（不存在就插入）能把记录**重新插回去**，
  ///   于是「手滑清空回收站」也能救。
  ///
  /// 返回真正发生的变化（写回 + 删除，见 [UndoOutcome]）；历史里对应的条目会被删掉。
  Future<UndoOutcome> undoUpTo(int entryId) async {
    final entries = await _undo.recent();
    // recent() 已按 id 降序，这里天然就是「新 → 旧」
    final targets = <UndoEntryEntity>[
      for (final e in entries)
        if (e.id >= entryId) e,
    ];
    if (targets.isEmpty) return UndoOutcome.none;

    // 同一条记录可能被多步操作碰过：**取最旧的那份**（= 这些操作都没发生时的状态）。
    // 按「新 → 旧」遍历并覆盖写入 map，最后每个 id 留下的就是最旧那份。
    final byId = <String, RecordEntity>{};
    // 这几步里「新插入」的 id 并集：撤销后它们不该存在（schema v8）。
    // 用 Set 去重 —— 同一批记录可能被多步导入反复写入。
    final inserted = <String>{};
    for (final entry in targets) {
      for (final record in RecordSnapshot.decode(entry.snapshot, bookId: _dao.bookId)) {
        byId[record.id] = record;
      }
      inserted.addAll(entry.insertedRecordIds);
    }
    // 一步里既覆盖又新增是不可能的（同 id 要么本来就在，要么是新的），
    // 所以这里不必处理「同一 id 既写回又删除」的冲突。

    // 写回数据与删除历史必须原子（2026-10-27 审查 m-010）：只写回一半、
    // 历史却还在，用户再点一次会重复写回；反过来历史没了、数据没写回则无法重试。
    await transaction(() async {
      await _dao.restoreRows(byId.values.toList(growable: false));
      // **必须放在写回之后**：导入之后又编辑过的新增行，会出现在「编辑」那一步的
      // 快照里，写回时会被重新 INSERT 进来；先删后写等于白删。
      await _dao.hardDeleteMany(inserted.toList(growable: false));
      await _undo.deleteFrom(entryId);
    });
    // 计数要扣掉「写回之后又被删掉」的那些：导入后编辑过的行会出现在编辑那一步
    // 的快照里，写回一次再删掉，如实算作「还原」会让提示条自相矛盾
    // （「还原 1 条、删除新增的 1 条」其实说的是同一行）。
    final restoredCount = byId.keys
        .where((String id) => !inserted.contains(id))
        .length;
    return UndoOutcome(restored: restoredCount, removed: inserted.length);
  }

  // ── CSV 导入 ────────────────────────────────────────────────────────

  /// 批量写入（导入用）：同 id 覆盖，新 id 插入。
  /// 解析工作由 `domain/csv_util.dart` 完成，本层只负责持久化。
  ///
  /// 返回**实际写入的 id**：调用方拿它与「导入前的既有 id」求差集，
  /// 得到「这次新增了哪些行」，交给 [pushUndo] 的 `insertedIds` 用于撤销。
  Future<List<String>> upsertRecords(List<RecordEntity> records) =>
      _dao.upsertAll(records.map(_toCompanion).toList());

  /// 批量写入，**每行按自己的 `book_id` 落库**（多记录本导入用）。
  ///
  /// 与 [upsertRecords] 的分工：那个把整批写进当前本（单本导入的语义），
  /// 这个尊重文件里的归属。id 与其它本撞车时的处理在 DAO 里，
  /// 两个入口共用同一套「不夺走别人的行」的规则。
  ///
  /// 同样返回实际写入的 id（撤销「新增」要用）。
  Future<List<String>> upsertRecordsInBooks(List<RecordEntity> records) =>
      _dao.upsertAllInBooks(records.map(_toCompanion).toList());

  /// 把 CSV 解析出的实体转成写入用的 companion。
  ///
  /// `deletedAt` 必须一起写：导入行的 `deleted` 恒为 false（CSV 不含回收站内容），
  /// 若让库里的旧值留着，就会出现「未删除却带着删除时刻」的行 ——
  /// 与 `restore()` 维持的不变式冲突，后续任何按 `deletedAt` 的判断都会错。
  RecordsCompanion _toCompanion(RecordEntity r) => RecordsCompanion(
        id: Value(r.id),
        // 带上 book_id：多本导入要按行归属写入（单本路径的 DAO 会再覆盖一次，
        // 所以这里多写一个值不会让「导入到当前本」的行为发生变化）。
        bookId: Value(r.bookId),
        title: Value(r.title),
        content: Value(r.content),
        tags: Value(r.tags),
        recordedAt: Value(r.recordedAt),
        createdAt: Value(r.createdAt),
        updatedAt: Value(r.updatedAt),
        deleted: Value(r.deleted),
        deletedAt: Value(r.deletedAt),
        durationS: Value(r.durationS),
      );

  static String? _nullIfBlank(String? s) {
    if (s == null) return null;
    final trimmed = s.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
