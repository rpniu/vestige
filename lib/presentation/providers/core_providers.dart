import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';

/// 基础设施 Providers：数据库与仓储。上层只认 Repository。
///
/// 放在独立文件里，避免 records_provider 与 edit_record_provider 互相 import。

/// 全局唯一的数据库实例；ProviderContainer 销毁时关闭连接。
final appDatabaseProvider = Provider<VestigeDatabase>((ref) {
  final db = VestigeDatabase();
  ref.onDispose(db.close);
  return db;
});

final recordRepositoryProvider = Provider<RecordRepository>(
  (ref) => RecordRepository(ref.watch(appDatabaseProvider).recordDao),
);
