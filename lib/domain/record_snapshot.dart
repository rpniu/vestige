import 'dart:convert';

import 'package:vestige/data/database/app_database.dart';

/// 记录快照的 JSON 编解码。
///
/// 用途：撤销要在操作**之前**把受影响的记录整行存下来，撤销时按 id 写回去。
///
/// ## 为什么存整行，而不是存「反向操作」
///
/// 直觉上「批量加标签 #A」的撤销就是「批量去掉 #A」—— 但这是**错的**：
/// 如果某条记录本来就有 #A，加的时候是空操作，撤销却会把它删掉。
/// 同理，「批量移入回收站」的反向是「恢复」，但恢复会把 `deletedAt` 清成 null，
/// 丢掉「它原本在回收站里待了多久」。存快照就没有这些歧义 ——
/// 撤销 = 回到操作前的状态，字面意义上的。
///
/// ## 为什么手写而不是 json_serializable
///
/// 字段就这么几个，而且 [RecordEntity] 是 drift 生成的、不方便加注解。
/// 手写还顺手做了容错：单条解析失败就跳过那一条，而不是整个历史炸掉 ——
/// 少撤销一步是可以接受的，整个「操作历史」打不开不行。
class RecordSnapshot {
  const RecordSnapshot._();

  /// 快照格式版本。将来字段有增减时靠它做兼容。
  static const int version = 1;

  static String encode(List<RecordEntity> records) => jsonEncode(<String, Object?>{
        'v': version,
        'rows': <Map<String, Object?>>[
          for (final r in records) _encodeOne(r),
        ],
      });

  /// 解析快照；**解析不出来的部分会被丢掉**，不会抛。
  ///
  /// 返回空列表 = 这次撤销没有可写回的内容，调用方应当据此提示而不是静默成功。
  static List<RecordEntity> decode(String source) {
    final Object? root;
    try {
      root = jsonDecode(source);
    } on FormatException {
      return const <RecordEntity>[];
    }
    if (root is! Map<String, Object?>) return const <RecordEntity>[];
    final rows = root['rows'];
    if (rows is! List) return const <RecordEntity>[];

    final out = <RecordEntity>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final record = _decodeOne(row);
      if (record != null) out.add(record);
    }
    return out;
  }

  static Map<String, Object?> _encodeOne(RecordEntity r) => <String, Object?>{
        'id': r.id,
        'title': r.title,
        'content': r.content,
        'tags': r.tags,
        'recordedAt': r.recordedAt.toIso8601String(),
        'createdAt': r.createdAt.toIso8601String(),
        'updatedAt': r.updatedAt.toIso8601String(),
        'deleted': r.deleted,
        'deletedAt': r.deletedAt?.toIso8601String(),
      };

  /// 单条解析；缺关键字段或类型不对时返回 null（跳过这一条）。
  static RecordEntity? _decodeOne(Map<Object?, Object?> row) {
    final id = row['id'];
    final content = row['content'];
    final recordedAt = _time(row['recordedAt']);
    final createdAt = _time(row['createdAt']);
    final updatedAt = _time(row['updatedAt']);
    // 这四个缺一个就没法还原成一条合法记录（它们是 NOT NULL 列）
    if (id is! String || content is! String) return null;
    if (recordedAt == null || createdAt == null || updatedAt == null) return null;

    final rawTags = row['tags'];
    final tags = rawTags is List
        ? <String>[
            for (final t in rawTags)
              if (t is String) t,
          ]
        : const <String>[];

    final title = row['title'];
    return RecordEntity(
      id: id,
      title: title is String ? title : null,
      content: content,
      tags: tags,
      recordedAt: recordedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deleted: row['deleted'] == true,
      deletedAt: _time(row['deletedAt']),
    );
  }

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
