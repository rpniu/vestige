/// 记录本（多数据空间）的领域规则。
///
/// 命名说明：这个功能最初被叫作「项目」，但这个 App 记的是生活里的事，
/// 不是工程任务；「记录本」是用户本来就在做的事（记东西）的自然延伸 ——
/// 切换记录本 = 换一本继续记，不需要额外解释。
///
/// ## 存储形态（2026-10-27 定稿）
/// 一个数据库文件、两张主表、一条外键：
/// ```
/// record_books(id, name, created_at)
///        ↑ book_id  (ON DELETE CASCADE)
/// records(…)          undo_entries(…)
/// ```
/// 选它而不是「一个记录本一个 sqlite 文件」：单库便于整体备份，
/// 且 `records` 的读写仍走 drift 的类型化查询（隔离靠 `book_id` 过滤，
/// 过滤条件集中在 DAO 一处，不散在页面里）。
///
/// 本文件只放**与存储无关**的规则（默认本标识、名字校验），
/// 表结构在 `record_book_table.dart`，读写在各 DAO。
library;

/// 默认记录本 id。
///
/// 升级上来的老数据全部归入这一本：迁移时给既有记录统一填上这个 id，
/// 所以它**不可删除**，也不允许改名成一个空集合里的孤本。
const String kDefaultBookId = 'default';

/// 默认记录本的名字。
///
/// 叫「我的记录本」而不是「默认」：升级上来的用户会在这里看到自己已有的
/// 全部数据，界面不该用「默认」这种系统口径称呼它。
const String kDefaultBookName = '我的记录本';

/// 记录本名字的长度上限（按字符数，不是字节）。
///
/// 上限的目的是让列表行标题不换行 —— 超过这个长度在一行里会被截断，
/// 与其让用户写一个显示不全的名字，不如在输入时就拦住。
const int kMaxBookNameLength = 20;

/// 规范化用户输入的名字。
///
/// 返回 null 表示**不可用**（空、纯空白、超长），由 UI 给出提示；
/// 不静默截断 —— 截断会让用户以为自己写下的名字就是存下的名字。
String? normalizeBookName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return null;
  if (name.runes.length > kMaxBookNameLength) return null;
  return name;
}

/// 这条记录本是否就是默认那本。
bool isDefaultBook(String bookId) => bookId == kDefaultBookId;
