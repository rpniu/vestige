import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/connection/native.dart';
import 'package:vestige/data/database/record_dao.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/record_book_provider.dart';

/// 基础设施 Providers：数据库与仓储。上层只认 Repository。
///
/// 放在独立文件里，避免 records_provider 与 edit_record_provider 互相 import。

/// 全局唯一的数据库实例；ProviderContainer 销毁时关闭连接。
///
/// 注意它**不随记录本变化**：所有记录本在同一个库里，靠 `book_id` 区分。
/// 于是切换记录本只是一次「换过滤条件」，不涉及开关数据库连接 ——
/// 比「一个记录本一个文件」时那套「关旧库、开新库」简单得多，
/// 也不会出现「切换瞬间旧的流读到已关闭的库」这类问题。
final appDatabaseProvider = Provider<VestigeDatabase>((ref) {
  final db = VestigeDatabase(connect());
  ref.onDispose(() {
    // 延后一个微任务再关：容器销毁时可能还有流的取消动作在队列里，
    // 立刻 close 会让它们收到「database closed」并冒成未捕获异常。
    unawaited(Future<void>.microtask(db.close));
  });
  return db;
});

/// 当前记录本的仓储。
///
/// 这里 `watch` 了**实际生效的记录本 id**，于是切换记录本 = 换一个绑定了
/// 新 `book_id` 的 DAO：所有依赖仓储的流（列表 / 回收站 / 统计）自动重订阅，
/// 自动落到新本的数据上。页面不需要知道切换发生过。
final recordRepositoryProvider = Provider<RecordRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final bookId = ref.watch(activeBookIdProvider);
  return RecordRepository(RecordDao(db, bookId: bookId));
});
