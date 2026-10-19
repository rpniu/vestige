import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

/// 记录表 —— **v2 重新设计版**（对应原 Kotlin 的 RecordEntity）。
///
/// ## 为什么要重新设计
/// 原设计只有一个 `createdAt`，它同时承担了两个互相冲突的语义：
///   1. 这条记录**属于哪一天**（用于分组、统计、连续天数）；
///   2. 这条数据**什么时候被写进数据库**（审计用，永远不该变）。
///
/// 于是「忘了记录、隔几天补交」只能靠改 `createdAt` 来实现——把审计字段
/// 也一起改掉了，既分不清哪些是补记，也没法再回答「这条到底是哪天录的」。
///
/// ## v2 的做法：把一条时间戳拆成两条
/// - `recordedAt`：**业务日期**，这条记录属于哪一天。可编辑、可回填。
///   补记就是把新记录的 `recordedAt` 设为过去某天。
/// - `createdAt`：**入库时间**，系统写入的时刻。创建后永不修改。
/// - `updatedAt`：最后一次修改时间。
///
/// 两者不在同一天（按本地日历日比较）即判定为「补记」，
/// 见 `lib/domain/day_util.dart` 里的 `RecordEntityX.isBackfilled`。
///
/// ## 各处的取用规则
/// | 用途                     | 用哪个字段    |
/// |--------------------------|---------------|
/// | 列表按天分组             | recordedAt    |
/// | 统计图（月/年/近 N 天）   | recordedAt    |
/// | 连续打卡天数             | recordedAt    |
/// | 「补记」标记 / 审计       | createdAt     |
@TableIndex(name: 'idx_deleted', columns: {#deleted})
@TableIndex(name: 'idx_recorded_at', columns: {#recordedAt})
@DataClassName('RecordEntity')
class Records extends Table {
  /// 主键：UUID 字符串。插入未显式指定则自动生成，
  /// 等价于原 Kotlin 的 `val id: UUID = UUID.randomUUID()`。
  /// 用 String 而非 Uuid 列：路由参数、CSV 导入导出全是 String，省一层转换。
  TextColumn get id => text().clientDefault(() => const Uuid().v4())();

  /// 标题，可空。
  TextColumn get title => text().nullable()();

  /// 正文，非空（原设计即必填）。
  TextColumn get content => text()();

  /// 标签列表。原代码存逗号串，这里改 JSON 文本，避免标签里含逗号时错位。
  /// CSV 里仍然用 `;` 分隔，两种格式互不影响。
  TextColumn get tags => text().map(const TagsConverter())();

  /// 业务日期：这条记录**属于**哪一天。可编辑、可回填（补记）。
  /// 时间部分也保留（补记时默认沿用当前时刻，便于同一天内排序）。
  DateTimeColumn get recordedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  /// 入库时间：数据实际落库的时刻。创建后**永不修改**，用于识别补记与审计。
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  /// 最后修改时间；每次编辑由上层显式刷新。
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();

  /// 软删除标志。
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// 进回收站的时刻；不在回收站里时为 null。
  ///
  /// 为什么单独存一列、不复用 [updatedAt]：`updatedAt` 是「最后一次改内容的时刻」，
  /// 它在删除**之前** —— 拿它当删除时间会**把刚删的记录误判成早就该清理**
  /// （一条半年前写的记录昨天才删，按 `updatedAt` 算是「在回收站放了半年」）。
  /// 回收站保留期要拿它做判断，算错就等于提示用户删掉刚删的东西。
  ///
  /// 恢复时清回 null，于是「恢复 → 再删」会重新开始计时。
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 将 `List<String>` 与 JSON 文本互转，用作 tags 列的存储格式。
class TagsConverter extends TypeConverter<List<String>, String> {
  const TagsConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    try {
      final decoded = jsonDecode(fromDb);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // 兼容手工写入的旧逗号串（RecordConverters 时代）
      return fromDb.split(',').where((e) => e.trim().isNotEmpty).toList();
    }
    return const [];
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}
