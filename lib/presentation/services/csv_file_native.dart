import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
