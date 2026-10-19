library;

/// 条件导出：按平台选择连接实现。
/// app_database.dart 只需 `import 'connection/connection.dart'` 即可拿到 connect()，
/// 平台差异对上层完全透明。
export './native.dart' if (dart.library.html) './web.dart';
