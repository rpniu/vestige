import 'package:drift/drift.dart';

/// 记录本表 —— 一份独立的数据空间只需一行。
///
/// ## 为什么记录本存进数据库、而不是 SharedPreferences
/// 一开始它放在偏好存储里（只存 id + 名字）。现在记录与它有了**外键关系**，
/// 两边分居两处就会失去一致性：比如删掉记录本的行、却忘了清偏好，
/// 或者反过来。放进同一个库，`ON DELETE CASCADE` 才能真的生效。
///
/// 偏好里只留一个 `record_books_active`（当前在用哪本）—— 那是**设备上的
/// 界面选择**，不是数据，换台设备本来就该重新选。
///
/// ## 与 Records / UndoEntries 的关系
/// ```
/// record_books(id) ←── book_id ── records
///                  ←── book_id ── undo_entries
/// ```
/// 两条外键都是 `ON DELETE CASCADE`：删掉一本 = 它的记录、它的撤销历史
/// 一起消失，不会留下「指向不存在记录本的孤儿行」。
@DataClassName('RecordBookEntity')
class RecordBooks extends Table {
  /// 记录本 id：默认那本是字面量 `default`，其余为 uuid v4。
  ///
  /// 用 Text 而不是自增整数：默认本需要一个**已知的固定值**才能在迁移里给
  /// 既有记录回填 `book_id`，自增 id 做不到这件事。
  TextColumn get id => text()();

  /// 展示名，用户可改。
  TextColumn get name => text()();

  /// 创建时刻。列表按它升序排 —— 先建的在上面，顺序稳定，
  /// 不会因为改个名字就跳动。
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
