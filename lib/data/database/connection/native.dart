import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

/// 覆盖数据目录的环境变量名（Windows / Linux / macOS 通用）。
///
/// 用途：让同一台机器上的多个系统（比如 Windows + Linux）指向**同一个**
/// 数据目录，而不是各写各的文档目录 —— 否则两边会各看到一份空数据。
///
/// 它解决的是「两个系统读写同一份数据」，前置条件是两边都能访问那个目录
/// （共享分区，或 WSL 下的 `/mnt/<盘符>/...`）。详见 README「多系统共用一份数据」。
const String dataDirEnvKey = 'VESTIGE_DATA_DIR';

/// 数据库文件名（各平台一致）。
///
/// 名字从最早的版本沿用至今 —— 位置搬过两次，但文件一直叫这个，
/// 迁移与排查脚本认的就是它。
const String databaseFileName = 'vestige.sqlite';

/// 存放数据的子目录名。
///
/// 数据不直接躺在文档目录根下，而是收进 `<文档>/vestige/` 里：文档目录是
/// 用户自己的地方，散一堆文件在外面既不好管理，也容易被误删/误同步。
/// 收进同名子目录后，「要备份就整个文件夹拷走、要清空就整个删掉」，边界很清楚。
const String dataSubDirName = 'vestige';

/// 数据库所在的子目录名。
///
/// 数据目录里除了库，还会有 `config/`（首页按钮位置等）、导出文件等。
/// 把 .sqlite 与它的 `-wal` / `-shm` 收进 `databases/`，是为了让「哪些是数据库
/// 文件」这件事一眼可见 —— 备份时可以只拷这一层，排查时也不会混进别的文件。
const String databasesSubDirName = 'databases';

/// 解析环境变量里指定的数据目录。
///
/// 抽成接受 [env] 参数的纯函数是为了能单测 —— 直接读 `Platform.environment`
/// 在测试里没法干净地塞值。
///
/// 返回 null 表示「没配置，走默认」：未设置、空串、纯空白都算没配置，
/// 免得手滑写成空值就把数据库丢到当前工作目录去了。
String? dataDirOverride([Map<String, String>? env]) {
  final raw = (env ?? Platform.environment)[dataDirEnvKey];
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 解析出最终使用的数据库文件，必要时创建目录、并把老数据搬进来。
///
/// [defaultDir] 传「平台的文档目录」—— 做成参数而不是内部直接调
/// `getApplicationDocumentsDirectory()`，是为了能在单测里塞一个临时目录
/// （path_provider 依赖平台通道，测试环境里调不动）。
///
/// 数据目录的优先级：
/// 1. 环境变量 [dataDirEnvKey] 指定的目录（跨系统共用同一份数据时才需要设）；
/// 2. `<文档目录>/vestige/`（默认）。
///
/// 库文件固定在 `<数据目录>/databases/vestige.sqlite` —— 一个库装下所有记录本
/// （它们靠 `record_books` 外键区分，不再一个记录本一个文件）。
///
/// 打开时会先做一次**文件搬家**（[_adoptLegacyDatabase]）：历史上库待过两个
/// 更浅的位置，这里把它收进 `databases/`，用户不会看到空数据。
Future<File> resolveDatabaseFile({
  required Future<Directory> Function() defaultDir,
  Map<String, String>? env,
}) async {
  final override = dataDirOverride(env);

  // 文档目录只在「没有指定数据目录」时才需要：最老那个位置
  // （`<文档>/vestige.sqlite`）只有那时才可能存在。
  Directory? docs;
  final Directory root;
  if (override != null) {
    root = Directory(override);
  } else {
    docs = await defaultDir();
    root = Directory('${docs.path}/$dataSubDirName');
  }
  await _ensureDir(root);

  final databases = Directory('${root.path}/$databasesSubDirName');
  await _ensureDir(databases);
  final target = File('${databases.path}/$databaseFileName');

  await _adoptLegacyDatabase(root: root, docs: docs, target: target);
  return target;
}

/// 把老位置的库搬进 `databases/`。
///
/// 两个历史位置，**从新到旧**依次尝试：
/// 1. `<数据目录>/vestige.sqlite`（「记录本放在数据目录根下」那一版）；
/// 2. `<文档目录>/vestige.sqlite`（最早那版，直接躺在文档目录里）。
///
/// 不做这一步的后果很具体：升级后新位置是空的，App 打开一片空白，
/// 用户以为数据丢了（文件其实还在旧地方躺着）。
///
/// 目标已存在时**什么都不做**（绝不覆盖）—— 两份都有数据时宁可不动，
/// 也不能拿旧的去冲掉正在用的那一份。
Future<void> _adoptLegacyDatabase({
  required Directory root,
  required Directory? docs,
  required File target,
}) async {
  if (await target.exists()) return;
  if (await _moveDatabase(File('${root.path}/$databaseFileName'), target)) {
    return;
  }
  if (docs != null) {
    await _moveDatabase(File('${docs.path}/$databaseFileName'), target);
  }
}

/// 把一份数据库**连同它的 `-wal` / `-shm` 伴生文件**移动到 [target]。
///
/// 伴生文件不能漏：WAL 模式下有已提交但尚未 checkpoint 回主文件的事务，
/// 只搬主文件会丢掉最近写入的内容 —— 而迁移恰恰发生在「升级后第一次启动」，
/// 那时候用户刚写的东西还在 wal 里，丢在这里最难解释。
///
/// 三条安全约定：
/// - **绝不覆盖**：目标已存在时直接放弃（两边都有数据时，宁可不动）；
/// - 优先 `rename`（同目录内是原子的移动）；跨设备 / 权限失败时退回复制；
/// - 复制成功后会尝试删除源文件；删不掉就留着当备份，不影响正确性。
///
/// 返回是否成功把主文件搬过去了。
Future<bool> _moveDatabase(File source, File target) async {
  if (await target.exists()) return false;
  if (!await source.exists()) return false;

  var movedMain = false;
  for (final suffix in <String>['', '-wal', '-shm']) {
    final from = File('${source.path}$suffix');
    final to = File('${target.path}$suffix');
    if (!await from.exists()) continue;
    try {
      await from.rename(to.path);
    } on FileSystemException {
      // 跨设备或权限不足：复制后删源。复制失败就整体放弃（数据留在原处，
      // 新位置没有库 → 下次启动会再试一次），不做任何破坏性动作。
      try {
        await from.copy(to.path);
      } on FileSystemException {
        if (suffix.isEmpty) return false;
        continue;
      }
      try {
        await from.delete();
      } on FileSystemException {
        // 源文件保留 = 多一份备份；此时目标已经可用，继续
      }
    }
    if (suffix.isEmpty) movedMain = true;
  }
  return movedMain;
}

Future<void> _ensureDir(Directory dir) async {
  if (!await dir.exists()) {
    // 目标目录可能还不存在（首次运行、共享分区刚挂上），先建出来再交给 sqlite
    await dir.create(recursive: true);
  }
}

/// 原生平台（Android / iOS / Windows / macOS / Linux）连接：
/// 库文件落在 `<数据目录>/databases/vestige.sqlite`，底层走 sqlite3_flutter_libs。
///
/// 只有**一个**库、一个连接：所有记录本在同一库里靠 `book_id` 区分，
/// 切换记录本不需要开关数据库。
QueryExecutor connect() {
  // LazyDatabase 包一层 async，让构造器本身保持同步
  return LazyDatabase(() async {
    final file = await resolveDatabaseFile(
      defaultDir: getApplicationDocumentsDirectory,
    );
    return NativeDatabase.createInBackground(file);
  });
}
