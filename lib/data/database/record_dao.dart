import 'package:drift/drift.dart';
import 'package:vestige/domain/record_book.dart';

import 'app_database.dart';
import 'record.dart';

part 'record_dao.g.dart';

/// 搜索结果条数上限。
///
/// 搜索是逐键触发的，一口气返回几万条没有意义，超出只会让用户更难翻。
/// 定义成公开常量是为了让 UI 能**如实说明**「结果被截断了」——
/// 否则「共 200 条结果」会被读成「一共就这么多」（2026-10-27 审查 m-002）。
const int kSearchResultLimit = 200;

/// 记录 DAO（对应原 Kotlin 的 RecordDao，v2 版）。
///
/// 与 v1 的差别：所有列表/排序一律按 **recordedAt**（业务日期）而非 createdAt，
/// 这样补记进来的记录会落在它「属于」的那一天，而不是排到列表最前面。
/// 所有响应式查询以 `watch` 前缀返回 Stream，等价原 Room 的 Flow。
///
/// ## 记录本隔离（v7）
/// 每个实例绑定**一个记录本**（[bookId]），所有读写都带上 `book_id` 条件。
/// 隔离靠这一处收口，而不是让每个调用方自己记得加过滤 ——
/// 「某处忘了 where」正是单表方案最容易踩的坑，所以这里把条件写进
/// `_inBook`，任何新方法只要拼上它就自动被隔离。
@DriftAccessor(tables: [Records])
class RecordDao extends DatabaseAccessor<VestigeDatabase>
    with _$RecordDaoMixin {
  RecordDao(super.db, {this.bookId = kDefaultBookId});

  /// 本 DAO 负责的记录本。
  final String bookId;

  /// 记录本过滤条件 —— 所有查询/更新的公共前提。
  Expression<bool> get _inBook => records.bookId.equals(bookId);

  /// 活跃记录（未软删），按业务日期倒序。响应式 Stream。
  Stream<List<RecordEntity>> watchAllActive() => _activeQuery().watch();

  /// 按 id 查单条（编辑页加载用）。
  ///
  /// 仍然带上 `book_id`：id 是 uuid，理论上全局唯一，但「查得到别的本的记录」
  /// 这件事本身就不该发生 —— 隔离条件不因「反正不会撞」而省。
  Future<RecordEntity?> getById(String id) => (select(records)
        ..where((r) => r.id.equals(id) & _inBook))
      .getSingleOrNull();

  /// 按一批 id 查（批量改标签用 —— 每行要并上**自己已有的**标签，所以得先读出来）。
  Future<List<RecordEntity>> getByIds(List<String> ids) {
    if (ids.isEmpty) return Future<List<RecordEntity>>.value(const []);
    return (select(records)..where((r) => r.id.isIn(ids) & _inBook)).get();
  }

  /// 新增。调用方用 `RecordsCompanion.insert(...)`；id / 时间戳留空则由
  /// clientDefault 生成（recordedAt 默认今天此刻）。
  ///
  /// `book_id` 由 DAO 强制写入，调用方传什么都不影响 —— 避免「复制一段插入
  /// 代码忘了改 bookId」把记录写进另一本。
  Future<void> insert(RecordsCompanion entry) =>
      into(records).insert(entry.copyWith(bookId: Value(bookId)));

  /// 更新。entry 必须包含 id。
  /// 注意：方法名不能用 `update`，会与 drift 自带的 update() 构造器冲突。
  Future<int> replace(RecordsCompanion entry) {
    if (!entry.id.present) {
      throw ArgumentError('replace 必须提供 id');
    }
    final id = entry.id.value;
    return (update(records)
          ..where((r) => r.id.equals(id) & _inBook))
        .write(entry.copyWith(bookId: Value(bookId)));
  }

  /// 批量 upsert（CSV 导入用）：同 id 覆盖，新 id 插入。单事务执行。
  Future<int> upsertAll(List<RecordsCompanion> entries) async {
    if (entries.isEmpty) return 0;
    final scoped = <RecordsCompanion>[
      for (final e in entries) e.copyWith(bookId: Value(bookId)),
    ];
    await batch((b) => b.insertAllOnConflictUpdate(records, scoped));
    return entries.length;
  }

  /// 软删除单条：打上 `deleted`，并**记下进回收站的时刻**（回收站保留期要用）。
  Future<void> softDelete(String id) =>
      (update(records)..where((r) => r.id.equals(id) & _inBook)).write(
        RecordsCompanion(
          deleted: const Value(true),
          deletedAt: Value(DateTime.now()),
        ),
      );

  /// 批量软删除。空列表直接返回：`IN ()` 是非法 SQL。
  Future<void> softDeleteMany(List<String> ids) {
    if (ids.isEmpty) return Future<void>.value();
    return (update(records)..where((r) => r.id.isIn(ids) & _inBook)).write(
      RecordsCompanion(
        deleted: const Value(true),
        deletedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 活跃记录同步获取（CSV 导出用），按业务日期倒序。
  Future<List<RecordEntity>> getAllActiveSync() => _activeQuery().get();

  /// 全文搜索：标题 / 正文 / 标签里包含 [query] 的活跃记录，按业务日期倒序。
  ///
  /// [from] / [to] 限定**业务日期**范围，**左闭右开**（`[from, to)`）——
  /// 右开是为了让调用方不必去算「某月最后一秒是几点几分」，
  /// 直接传下个月 1 号零点即可。
  ///
  /// [query] 为空时**只有给了日期范围才会查**（= 浏览某段时间的全部记录）。
  /// 既无关键词也无范围时返回空：这种调用没有意义，不应把全库查询出来。
  ///
  /// SQLite 的 LIKE 对 ASCII 大小写不敏感，中文没有大小写概念，所以不用
  /// 额外处理大小写。`%` 与 `_` 是 LIKE 的通配符，先转义再拼模式串 ——
  /// 否则用户搜「100%」会变成「100 开头的一切」。
  /// 标签列是 JSON 文本（`["运动","读书"]`），LIKE 走包含匹配，与
  /// 「标签里含这个词」的直觉一致。
  ///
  /// [limit] 兜底结果条数：搜索是逐键触发的，一口气返回几万条没有意义，
  /// 超出只会让用户更难翻。
  Future<List<RecordEntity>> searchActive(
    String query, {
    int limit = kSearchResultLimit,
    DateTime? from,
    DateTime? to,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty && from == null && to == null) {
      return Future<List<RecordEntity>>.value(const []);
    }

    final conditions = <Expression<bool>>[_inBook, records.deleted.equals(false)];
    if (trimmed.isNotEmpty) {
      final pattern = '%${_escapeLike(trimmed)}%';
      conditions.add(
        records.title.like(pattern, escapeChar: r'\') |
            records.content.like(pattern, escapeChar: r'\') |
            records.tags.like(pattern, escapeChar: r'\'),
      );
    }
    if (from != null) {
      conditions.add(records.recordedAt.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      conditions.add(records.recordedAt.isSmallerThanValue(to));
    }
    final condition = conditions.reduce((Expression<bool> a, Expression<bool> b) => a & b);

    return (select(records)
          ..where((r) => condition)
          ..orderBy([(r) => OrderingTerm.desc(r.recordedAt)])
          ..limit(limit))
        .get();
  }

  /// 转义 LIKE 模式串里的 `\`、`%`、`_`（转义符固定用 `\`）。
  static String _escapeLike(String raw) => raw
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 回收站记录（已软删），按最后修改时间倒序。响应式 Stream。
  Stream<List<RecordEntity>> watchDeleted() => (select(records)
        ..where((r) => r.deleted.equals(true) & _inBook)
        ..orderBy([(r) => OrderingTerm.desc(r.updatedAt)]))
      .watch();

  /// 回收站记录的同步获取（**清空回收站前存快照用**）。
  Future<List<RecordEntity>> getDeletedSync() =>
      (select(records)..where((r) => r.deleted.equals(true) & _inBook)).get();

  /// 恢复单条：清掉 `deleted`，也清掉 `deletedAt` —— 再删一次会**重新开始计时**。
  Future<void> restore(String id) =>
      (update(records)..where((r) => r.id.equals(id) & _inBook)).write(
        const RecordsCompanion(
          deleted: Value(false),
          deletedAt: Value<DateTime?>(null),
        ),
      );

  /// 批量恢复。空列表直接返回：`IN ()` 是非法 SQL。
  Future<void> restoreMany(List<String> ids) {
    if (ids.isEmpty) return Future<void>.value();
    return (update(records)..where((r) => r.id.isIn(ids) & _inBook)).write(
      const RecordsCompanion(
        deleted: Value(false),
        deletedAt: Value<DateTime?>(null),
      ),
    );
  }

  /// 彻底删除单条。
  Future<void> hardDelete(String id) =>
      (delete(records)..where((r) => r.id.equals(id) & _inBook)).go();

  /// 批量彻底删除。空列表直接返回：`IN ()` 是非法 SQL。
  Future<void> hardDeleteMany(List<String> ids) {
    if (ids.isEmpty) return Future<void>.value();
    return (delete(records)..where((r) => r.id.isIn(ids) & _inBook)).go();
  }

  /// 清空回收站。
  Future<int> emptyTrash() =>
      (delete(records)..where((r) => r.deleted.equals(true) & _inBook)).go();

  /// 批量平移业务日期：[delta] 秒直接加到 `recorded_at` 上。
  ///
  /// 为什么走裸 SQL：drift 的 `update(..).write(companion)` 只能写**字面值**，
  /// 表达不了「在原值基础上加一个增量」。而旧写法是「逐条查出来、再逐条写回去」，
  /// 平移 500 条 = 1000 次独立语句（每次各自一个隐式事务），选中一批再点一下「+1 天」
  /// 要卡好几秒。这里一条 UPDATE 解决。
  ///
  /// drift 默认把 dateTime 存成 Unix 秒（INTEGER），所以「加 [delta] 秒」与 Dart 侧的
  /// `recordedAt.add(delta)` 完全等价 —— 语义没有变化，只是不再把数据搬到 Dart 层。
  ///
  /// 占位符按 id 个数展开。用途是手动多选（长按勾选），实际量级在几十条，
  /// 远低于 SQLite 的变量上限（3.32+ 为 32766）。
  ///
  /// `book_id` 条件必须留在 WHERE 里：裸 SQL 不经过 [_inBook]，
  /// 漏掉它这条 UPDATE 就会跨记录本改数据。
  Future<int> shiftRecordedAt(List<String> ids, Duration delta) {
    if (ids.isEmpty) return Future<int>.value(0);
    final placeholders = List<String>.filled(ids.length, '?').join(', ');
    return customUpdate(
      'UPDATE records '
      'SET recorded_at = recorded_at + ?, updated_at = ? '
      'WHERE book_id = ? AND id IN ($placeholders)',
      variables: <Variable<Object>>[
        Variable<int>(delta.inSeconds),
        Variable<DateTime>(DateTime.now()),
        Variable<String>(bookId),
        for (final id in ids) Variable<String>(id),
      ],
      // 声明影响的是哪张表，drift 才会通知依赖它的 stream 重新查询
      updates: {records},
      updateKind: UpdateKind.update,
    );
  }

  /// 批量改标签：[tagsById] 是「id → 这一条改完之后的新标签」。
  ///
  /// 为什么不像 [shiftRecordedAt] 那样压成一条 UPDATE：那里每行的增量都一样，
  /// 而标签是**逐行不同**的（各自并上自己已有的标签），SQL 表达不了。
  /// 所以逐条写 —— 但走 `batch`，它整体包在一个事务里，
  /// 不会出现「一半记录打了标签、另一半没打」的中间态。
  Future<void> updateTagsMany(Map<String, List<String>> tagsById) async {
    if (tagsById.isEmpty) return;
    final now = DateTime.now();
    await batch((Batch b) {
      for (final entry in tagsById.entries) {
        b.update(
          records,
          RecordsCompanion(
            tags: Value(entry.value),
            updatedAt: Value(now),
          ),
          where: (r) => r.id.equals(entry.key) & _inBook,
        );
      }
    });
  }

  /// 把快照里的整行写回去：**存在就整行覆盖，不存在就插入**。
  ///
  /// 为什么不用 `upsertAll`（drift 的 `insertAllOnConflictUpdate`）：
  /// 它对「显式置 null」的列不生效 —— 实测撤销「移入回收站」之后
  /// `deleted_at` 还留着旧值，于是那条记录一回到列表就被保留期判成「超期」。
  ///
  /// 所以拆成两步，都是 drift 的标准写法：
  /// 1. 先当 `UPDATE` 写 —— 它会如实把 `Value(null)` 写进去（这正是 upsert 做不到的）；
  /// 2. 影响 0 行说明这行**已经被彻底删掉了** → 用 `INSERT` 插回去。
  ///
  /// 第 2 步是「撤销清空回收站」能救回记录的关键。
  ///
  /// 列清单必须与 `RecordsCompanion` 的全部可写列保持同步 —— 漏一列，
  /// 「撤销彻底删除」把它插回来时那一列就是空值（`durationS` 曾因此丢失）。
  ///
  /// **原子性由调用方提供**：`RecordRepository.undoUpTo` 把「写回 + 删历史」
  /// 包在同一个事务里。本方法自己不再开事务，避免双层包装产生嵌套事务。
  Future<void> restoreRows(List<RecordEntity> rows) async {
    if (rows.isEmpty) return;
    for (final r in rows) {
      // 不含 id：它是 WHERE 条件，不该被写进 SET
      final fields = RecordsCompanion(
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

      final affected = await (update(records)
            ..where((t) => t.id.equals(r.id) & _inBook))
          .write(fields);
      if (affected == 0) {
        await into(records).insert(
          fields.copyWith(id: Value(r.id), bookId: Value(bookId)),
        );
      }
    }
  }

  /// 活跃记录的基础查询：过滤软删与本记录本 + 按业务日期倒序。
  SimpleSelectStatement<$RecordsTable, RecordEntity> _activeQuery() =>
      select(records)
        ..where((r) => r.deleted.equals(false) & _inBook)
        ..orderBy([
          (r) => OrderingTerm.desc(r.recordedAt),
          // 同一天内：补记的先按入库顺序排，读起来符合「补交」直觉
          (r) => OrderingTerm.desc(r.createdAt),
        ]);
}
