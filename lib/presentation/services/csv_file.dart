/// 条件导出：CSV 落盘能力的平台实现。
///
/// 原因：`dart:io`（写文件）与 `path_provider` 在 Web 上不可用，而导入导出在
/// 原生平台需要真实文件。把平台差异封在这一层，页面代码保持平台无关
/// （与 `data/database/connection` 的做法一致）。
library;

export './csv_file_native.dart' if (dart.library.html) './csv_file_web.dart';
