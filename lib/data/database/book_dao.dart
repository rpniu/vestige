import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:vestige/domain/record_book.dart';

import 'app_database.dart';
import 'record_book_table.dart';

part 'book_dao.g.dart';

/// 记录本的读写。
///
/// 与 `RecordDao` / `UndoDao` 不同，它**不绑定**某个记录本 —— 它管的是
/// 「有哪些本」这件事本身。
///
/// 删除靠外键级联（`ON DELETE CASCADE`）：删掉一行记录本，它的记录与撤销历史
/// 一起消失。所以这里**不需要**手写「先删记录再删本」的顺序，
/// 也就不会出现「删了一半」的中间态。
@DriftAccessor(tables: [RecordBooks])
class BookDao extends DatabaseAccessor<VestigeDatabase> with _$BookDaoMixin {
  BookDao(super.db);

  /// 排序：**默认记录本永远在第一位**，其余按创建时刻升序（同刻按 id）。
  ///
  /// 不能只按 created_at 排：默认本那行是数据库打开时补的，与用户马上新建的
  /// 一本往往落在同一秒；SQLite 的秒级时间戳撞车后顺序就随 id 字面量走了，
  /// 结果「默认本不在第一个」—— 列表看起来像是别的一本才是主记录本。
  static List<OrderingTerm Function($RecordBooksTable)> get _ordering =>
      <OrderingTerm Function($RecordBooksTable)>[
        (t) => OrderingTerm(
          expression: t.id.equals(kDefaultBookId),
          mode: OrderingMode.desc,
        ),
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.id),
      ];

  /// 全部记录本，顺序见 [_ordering]。
  ///
  /// 用流而不是一次性查询：新建 / 改名 / 删除都从别的地方发生，
  /// 列表页跟着数据库自动刷新，不必手动 invalidate。
  Stream<List<RecordBookEntity>> watchAll() =>
      (select(recordBooks)..orderBy(_ordering)).watch();

  Future<List<RecordBookEntity>> getAll() =>
      (select(recordBooks)..orderBy(_ordering)).get();

  Future<RecordBookEntity?> byId(String id) =>
      (select(recordBooks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 记录本总数（删除前判「至少留一本」用）。
  Future<int> count() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS n FROM record_books',
      readsFrom: {recordBooks},
    ).getSingle();
    return row.data['n'] as int;
  }

  /// 新建。id 由这里生成（uuid v4），名字由调用方校验过。
  Future<RecordBookEntity> create(String name) async {
    final book = RecordBookEntity(
      id: const Uuid().v4(),
      name: name,
      createdAt: DateTime.now(),
    );
    await into(recordBooks).insert(book);
    return book;
  }

  /// 改名。返回是否真的改到了行。
  Future<bool> rename(String id, String name) async {
    final affected = await (update(recordBooks)
          ..where((t) => t.id.equals(id)))
        .write(RecordBooksCompanion(name: Value(name)));
    return affected > 0;
  }

  /// 删除一行（记录与撤销历史由外键级联清掉）。
  ///
  /// **不判断「是不是默认本 / 是不是当前本」** —— 那是业务规则，
  /// 由 `RecordBooksController` 统一裁决，DAO 只负责执行。
  Future<int> deleteById(String id) =>
      (delete(recordBooks)..where((t) => t.id.equals(id))).go();

  /// 是否已有同名记录本（[exceptId] 用于改名时排除自己）。
  Future<bool> nameExists(String name, {String? exceptId}) async {
    final rows = await (select(recordBooks)
          ..where(
            (t) => exceptId == null
                ? t.name.equals(name)
                : t.name.equals(name) & t.id.equals(exceptId).not(),
          )
          ..limit(1))
        .get();
    return rows.isNotEmpty;
  }

  /// 确保默认记录本存在。
  ///
  /// 数据库在 `beforeOpen` 里已经补过这一行（那是权威保障）；这里保留一个
  /// 可主动调用的入口，用于「先确保、再读」的调用方与测试夹具。
  /// `INSERT OR IGNORE` 语义，重复调用无副作用。
  Future<void> ensureDefault() async {
    await customStatement(
      'INSERT OR IGNORE INTO record_books (id, name, created_at) '
      "VALUES ('$kDefaultBookId', '$kDefaultBookName', "
      "CAST(strftime('%s','now') AS INTEGER))",
    );
  }
}
