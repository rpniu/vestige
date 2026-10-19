import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

/// 覆盖数据目录的环境变量名（Windows / Linux / macOS 通用）。
///
/// 用途：让同一台机器上的多个系统（比如 Windows + Linux）指向**同一个**
/// vestige.sqlite，而不是各写各的文档目录 —— 否则两边会各看到一份空数据。
///
/// 它解决的是「两个系统读写同一个数据文件」，前置条件是两边都能访问那个目录
/// （共享分区，或 WSL 下的 `/mnt/<盘符>/...`）。详见 README「多系统共用一份数据」。
const String dataDirEnvKey = 'VESTIGE_DATA_DIR';

/// 数据库文件名（各平台一致）。
const String databaseFileName = 'vestige.sqlite';

/// 存放数据库的子目录名。
///
/// 数据库不直接躺在文档目录根下（`<文档>/vestige.sqlite`），而是收进
/// `<文档>/vestige/` 里：文档目录是用户自己的地方，散一个 .sqlite 在外面
/// 既不好管理，也容易被误删/误同步。收进同名子目录后，
/// 「要备份就整个文件夹拷走、要清空就整个删掉」，边界很清楚。
const String dataSubDirName = 'vestige';

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
/// 优先级：
/// 1. 环境变量 [dataDirEnvKey] 指定的目录（跨系统共用同一份数据时才需要设）；
/// 2. `<文档目录>/vestige/vestige.sqlite`（默认）。
Future<File> resolveDatabaseFile({
  required Future<Directory> Function() defaultDir,
  Map<String, String>? env,
}) async {
  final override = dataDirOverride(env);
  if (override != null) {
    final dir = Directory(override);
    await _ensureDir(dir);
    // 用户明确指定了位置，就不再改动默认目录中的文件
    return File('${dir.path}/$databaseFileName');
  }

  final docs = await defaultDir();
  final target = Directory('${docs.path}/$dataSubDirName');
  await _ensureDir(target);
  final file = File('${target.path}/$databaseFileName');
  await _adoptLegacyFile(docs, file);
  return file;
}

Future<void> _ensureDir(Directory dir) async {
  if (!await dir.exists()) {
    // 目标目录可能还不存在（首次运行、共享分区刚挂上），先建出来再交给 sqlite
    await dir.create(recursive: true);
  }
}

/// 把「旧版直接放在文档目录根下」的库文件搬进子目录。
///
/// 不做这一步的后果很具体：升级后新位置是空的，App 打开一片空白，
/// 用户以为数据丢了（文件其实还在旧地方躺着）。
///
/// 只在新位置没有库、旧位置有库时才动手。用 `rename`（同一分区内的移动）
/// 而不是复制 —— 复制会留下两份，之后两边各写各的，比不迁移更糟。
Future<void> _adoptLegacyFile(Directory docs, File newFile) async {
  if (await newFile.exists()) return;

  final legacy = File('${docs.path}/$databaseFileName');
  if (!await legacy.exists()) return;

  try {
    await legacy.rename(newFile.path);
  } on FileSystemException {
    // rename 跨设备/权限失败时退回复制：宁可多留一份旧的（当作备份），
    // 也不能因为搬不动就让用户的数据在新位置「消失」。
    await legacy.copy(newFile.path);
  }
}

/// 原生平台（Android / iOS / Windows / macOS / Linux）连接：
/// 数据库文件落在应用文档目录下的 `vestige/` 子目录，底层走 sqlite3_flutter_libs。
QueryExecutor connect() {
  // LazyDatabase 包一层 async，让构造器本身保持同步
  return LazyDatabase(() async {
    final file = await resolveDatabaseFile(
      defaultDir: getApplicationDocumentsDirectory,
    );
    return NativeDatabase.createInBackground(file);
  });
}
