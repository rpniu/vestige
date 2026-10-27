import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// CSV 落盘能力（原生实现）。
///
/// 2026-10-27：**Web 目标已移除**（用户决定）。此前这里是一层条件导出
/// （`if (dart.library.js_interop) csv_file_web.dart`），web 版本恒失败、
/// 让页面退回「分享文本」；现在只剩原生实现，平台分支不再需要。
///
/// 两个函数都**不抛异常**，用返回值表达结果：失败路径（磁盘满、权限、
/// 临时目录不可写）在真实设备上很常见，让调用方用 `try/catch` 接住反而容易漏；
/// 返回 null / false 时页面会明确提示用户。

/// 把 CSV 写进应用临时目录，返回文件路径（移动端交给系统分享用）。
/// 失败返回 null，调用方应退回「分享文本」。
Future<String?> writeTempCsv(String csv, String fileName) async {
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(csv);
    return file.path;
  } catch (_) {
    return null;
  }
}

/// 把 CSV 写到用户选定的路径（桌面端「另存为」用）。
Future<bool> writeCsvToPath(String path, String csv) async {
  try {
    await File(path).writeAsString(csv, flush: true);
    return true;
  } catch (_) {
    return false;
  }
}
