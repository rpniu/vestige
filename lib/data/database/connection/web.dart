import 'package:drift/drift.dart';
import 'package:drift/web.dart';

/// Web 平台连接：使用 IndexedDB（非文件），库名 'vestige'。
QueryExecutor connect() {
  return WebDatabase('vestige');
}
