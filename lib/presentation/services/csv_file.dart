import 'dart:io';

/// CSV 落盘能力（桌面端）。
///
/// 移动端不需要在这里落盘：`flutter_file_dialog` 的 saveFile 支持直接传字节，
/// 由插件在用户确认保存位置后写入（见 profile_screen._exportCsv）。
///
/// 2026-10-27：**Web 目标已移除**（用户决定）。此前这里是一层条件导出
/// （`if (dart.library.js_interop) csv_file_web.dart`），web 版本恒失败、
/// 让页面退回「分享文本」；现在只剩原生实现，平台分支不再需要。
///
/// 不抛异常，用返回值表达结果：失败路径（磁盘满、权限、目录不可写）在真实设备上
/// 很常见，让调用方用 `try/catch` 接住反而容易漏；返回 false 时页面会明确提示用户。
///
/// 把 CSV 写到用户选定的路径（桌面端「另存为」用）。
Future<bool> writeCsvToPath(String path, String csv) async {
  try {
    await File(path).writeAsString(csv, flush: true);
    return true;
  } catch (_) {
    return false;
  }
}
