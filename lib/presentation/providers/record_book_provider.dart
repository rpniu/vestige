import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/book_dao.dart';
import 'package:vestige/domain/record_book.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

/// 记录本（多数据空间）：当前本、列表、增删改。
///
/// ## 两层数据，职责不同
/// - **记录本有哪些、叫什么** → 数据库 `record_books` 表（权威）。
///   只有记录本页读它，用的是响应式流。
/// - **我现在在用哪一本** → SharedPreferences（设备上的界面选择）。
///   首页、「我的」只读这一层，**不碰数据库**。
///
/// 为什么要这层缓存：首页标识条与「我的」页副标题都要显示当前本的名字。
/// 如果为此去订阅数据库，那么任何一次页面构建都会牵扯到「打开数据库」——
/// 在 widget 测试里（没有平台通道）这会直接把测试挂死，真机上也是一次
/// 不必要的 IO。名字只是几十字节的界面状态，放偏好里最合适。
///
/// 缓存与数据库**由同一个控制器写入**（见 [RecordBooksController]），
/// 所以不会各说各话；即便某次写入失败，最坏也只是显示旧名字，
/// 而记录本页永远显示数据库里的真值。

/// 记录本的读写入口（只在记录本页用）。
final bookDaoProvider = Provider<BookDao>(
  (ref) => BookDao(ref.watch(appDatabaseProvider)),
);

/// 全部记录本，按「默认本在前 + 创建时刻」排序。
///
/// 数据源是数据库的响应式流，新建 / 改名 / 删除后界面自动刷新。
/// 开流前先 `ensureDefault()`：全新库里 `record_books` 是空表，
/// 而外键与界面都假定「默认记录本存在」（数据库 `beforeOpen` 也补了一次，
/// 这里是双保险）。
final recordBooksProvider = StreamProvider<List<RecordBookEntity>>((ref) {
  final dao = ref.watch(bookDaoProvider);
  return Stream<void>.fromFuture(dao.ensureDefault())
      .asyncExpand((_) => dao.watchAll());
});

/// 当前记录本（id + 名字 + 总数），来自偏好缓存。
class ActiveBook {
  const ActiveBook({
    required this.id,
    required this.name,
    required this.count,
  });

  /// 记录本 id。
  final String id;

  /// 展示名。
  final String name;

  /// 有几本（「我的」页那句「共 N 个记录本」用）。由控制器在增删后刷新，
  /// 不是实时统计 —— 界面只需要一个大致准确的数字。
  final int count;

  bool get isDefault => isDefaultBook(id);

  @override
  bool operator ==(Object other) =>
      other is ActiveBook &&
      other.id == id &&
      other.name == name &&
      other.count == count;

  @override
  int get hashCode => Object.hash(id, name, count);

  static const ActiveBook initial = ActiveBook(
    id: kDefaultBookId,
    name: kDefaultBookName,
    count: 1,
  );
}

final activeBookProvider =
    NotifierProvider<ActiveBookController, ActiveBook>(ActiveBookController.new);

class ActiveBookController extends Notifier<ActiveBook> {
  static const String _keyId = 'record_books_active';
  static const String _keyName = 'record_books_active_name';
  static const String _keyCount = 'record_books_count';

  @override
  ActiveBook build() {
    final prefs = _prefsOrNull();
    if (prefs == null) {
      // 存储不可用（部分测试环境没 override prefs）：退成默认本，不至于白屏。
      return ActiveBook.initial;
    }
    final id = prefs.getString(_keyId);
    return ActiveBook(
      id: (id == null || id.isEmpty) ? kDefaultBookId : id,
      name: prefs.getString(_keyName) ?? kDefaultBookName,
      count: prefs.getInt(_keyCount) ?? 1,
    );
  }

  SharedPreferences? _prefsOrNull() {
    try {
      return ref.watch(sharedPreferencesProvider);
    } catch (_) {
      return null;
    }
  }

  /// 直接改状态并落盘（控制器内部用；UI 请走 `RecordBooksController`）。
  ///
  /// 值没变时**不通知、不写盘**：记录本页在每次构建后都会校准一次缓存，
  /// 若无条件赋值，state 变化会触发重建 → 又校准 → 自激循环。
  Future<void> apply(ActiveBook next) async {
    if (next == state) return;
    state = next;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(_keyId, next.id);
      await prefs.setString(_keyName, next.name);
      await prefs.setInt(_keyCount, next.count);
    } catch (_) {
      // 写不进去只影响「下次启动还记得」，当前会话仍然生效
    }
  }
}

/// 当前记录本 id（仓储层按它过滤数据）。
final activeBookIdProvider = Provider<String>(
  (ref) => ref.watch(activeBookProvider).id,
);

/// 当前记录本名字（读不到时退回默认名，界面不该为这个空着）。
final activeBookNameProvider = Provider<String>(
  (ref) => ref.watch(activeBookProvider).name,
);

/// 记录本的增删改。业务规则集中在这里，DAO 只管执行。
///
/// 尤其是「哪些本不能删」：默认本（升级上来的那份数据）、当前正在用的本
/// （列表正读着它）、最后一本。
final recordBooksControllerProvider = Provider<RecordBooksController>(
  (ref) => RecordBooksController(ref),
);

class RecordBooksController {
  RecordBooksController(this._ref);

  final Ref _ref;

  BookDao get _dao => _ref.read(bookDaoProvider);
  ActiveBookController get _active => _ref.read(activeBookProvider.notifier);

  /// 把「当前本 + 总数」同步进偏好缓存。
  ///
  /// 每次增删改之后调用：数据库是权威，缓存跟着它走。
  Future<void> syncCache() async {
    final books = await _dao.getAll();
    if (books.isEmpty) return;
    final currentId = _ref.read(activeBookIdProvider);
    final current = books.where((b) => b.id == currentId).firstOrNull;
    // 当前本被删掉（或存下来的 id 已失效）→ 退回默认本（列表里排第一的那本）
    final resolved = current ?? books.first;
    await _active.apply(
      ActiveBook(
        id: resolved.id,
        name: resolved.name,
        count: books.length,
      ),
    );
  }

  /// 切换到另一本。返回是否真的切了（不存在 / 已经是它就 false）。
  ///
  /// 只改偏好里的当前本；数据库层的隔离由
  /// `recordRepositoryProvider` 监听到 id 变化后重建完成（见 core_providers）。
  Future<bool> switchTo(String bookId) async {
    final books = await _dao.getAll();
    final target = books.where((b) => b.id == bookId).firstOrNull;
    if (target == null) return false;
    if (_ref.read(activeBookIdProvider) == bookId) return false;
    await _active.apply(
      ActiveBook(id: target.id, name: target.name, count: books.length),
    );
    return true;
  }

  /// 新建记录本（**不自动切过去**）。
  ///
  /// 为什么不自动切：用户可能是「先建好、回头再整理」，突然换本会让首页
  /// 变成空白，像数据丢了。切不切由用户自己点。
  ///
  /// 返回新记录本；名字不合法或重名返回 null。
  Future<RecordBookEntity?> create(String rawName) async {
    final name = normalizeBookName(rawName);
    if (name == null) return null;
    if (await _dao.nameExists(name)) return null;
    final book = await _dao.create(name);
    await syncCache();
    return book;
  }

  /// 重命名。默认本**可以改名**（它只是「升级时带过来的那一份」，
  /// 用户可能想叫它「生活」），但仍然不可删除。
  Future<bool> rename(String bookId, String rawName) async {
    final name = normalizeBookName(rawName);
    if (name == null) return false;
    if (await _dao.nameExists(name, exceptId: bookId)) return false;
    final ok = await _dao.rename(bookId, name);
    if (ok) await syncCache();
    return ok;
  }

  /// 删除记录本（记录与撤销历史由外键级联删除）。
  ///
  /// 三条禁止，任一成立就返回 false 且**不动任何东西**：
  /// 1. 默认记录本不可删 —— 它承载升级前的那批数据；
  /// 2. 当前正在用的不可删 —— 列表正读着它，删完会盯着一个空表；
  /// 3. 至少留一本 —— 一本都没有的界面无从解释。
  Future<bool> delete(String bookId) async {
    if (isDefaultBook(bookId)) return false;
    if (bookId == _ref.read(activeBookIdProvider)) return false;
    if (await _dao.count() <= 1) return false;
    if (await _dao.byId(bookId) == null) return false;
    final removed = await _dao.deleteById(bookId) > 0;
    if (removed) await syncCache();
    return removed;
  }
}
