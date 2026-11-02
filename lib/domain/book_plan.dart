import 'package:vestige/domain/record_book.dart';

/// 导入时「文件里的记录本」落到本库哪一本的裁决。
///
/// 这条规则只有一个来源：预览弹层把它摊给用户看，真正写库时再用**同一个**
/// 函数算一遍 —— 两处各写一套必然走偏，而走偏的后果是「预览说会写进学习本，
/// 实际写进了默认本」这种无法事后解释的错。
///
/// 判定顺序（见 [planBooks]）：
/// 1. 本库里已有这个 id → 归入它（同库导出导入，最精确）；
/// 2. 否则文件里有名字、且库里存在同名本 → 归入同名本（跨设备场景）；
/// 3. 否则文件里有合法名字 → 新建一本；
/// 4. 名字缺失或不合法（空 / 超长）→ 默认记录本。
///
/// 注意第 4 条不丢数据：记录本认不出来是「归属不明」，不是「这条记录坏了」，
/// 所以记录照旧导入，只是落进默认本。

/// 一个记录本在导入时的去向。
enum BookTarget {
  /// 归入本库已有的记录本。
  existing,

  /// 本库里没有，需要新建。
  create,

  /// 认不出来，归入默认记录本。
  fallback,
}

/// 一个记录本的裁决结果（同时也是预览里的一行）。
class BookPlanEntry {
  const BookPlanEntry({
    required this.csvBookId,
    required this.label,
    required this.count,
    required this.target,
    this.targetBookId = kDefaultBookId,
    this.newName,
  });

  /// 文件里的记录本 id。
  final String csvBookId;

  /// 展示名：库里已有的名字优先，其次是文件里的名字，最后是兜底称呼。
  final String label;

  /// 这个记录本在文件里有多少条记录。
  final int count;

  /// 去向。
  final BookTarget target;

  /// 写入时的目标记录本 id（[BookTarget.create] 时是新建后的 id，
  /// 计划阶段先给出默认本占位，真正写库时再填）。
  final String targetBookId;

  /// [BookTarget.create] 时要新建的名字。
  final String? newName;

  /// 预览里給用户看的一句话去向说明。
  String get note => switch (target) {
        BookTarget.existing => '归入已有记录本',
        BookTarget.create => '将新建记录本',
        BookTarget.fallback => '文件里没有记录本信息，归入默认记录本',
      };
}

/// 算出每个「文件里的记录本」的去向。
///
/// [counts] 是「文件里的记录本 id → 条数」，[names] 是「文件里的 id → 名字」，
/// [existingIdNames] 是「本库的记录本 id → 名字」，[existingNames] 是
/// 「本库的记录本名字 → id」（后者用于跨设备时按名字重新认领）。
///
/// 顺序与 [counts] 一致（= 文件里首次出现的顺序），预览列表不会跳来跳去。
List<BookPlanEntry> planBooks({
  required Map<String, int> counts,
  required Map<String, String> names,
  required Map<String, String> existingIdNames,
  required Map<String, String> existingNames,
}) {
  final plan = <BookPlanEntry>[];
  for (final entry in counts.entries) {
    final csvBookId = entry.key;
    final count = entry.value;
    final rawName = names[csvBookId] ?? '';

    final sameBookName = existingIdNames[csvBookId];
    if (sameBookName != null) {
      // 库里已有的本：名字以**库里的**为准（文件里的名字可能已过时）
      plan.add(
        BookPlanEntry(
          csvBookId: csvBookId,
          label: sameBookName,
          count: count,
          target: BookTarget.existing,
          targetBookId: csvBookId,
        ),
      );
      continue;
    }

    final name = normalizeBookName(rawName);
    if (name == null) {
      plan.add(
        BookPlanEntry(
          csvBookId: csvBookId,
          label: kDefaultBookName,
          count: count,
          target: BookTarget.fallback,
        ),
      );
      continue;
    }

    final sameName = existingNames[name];
    if (sameName != null) {
      plan.add(
        BookPlanEntry(
          csvBookId: csvBookId,
          label: name,
          count: count,
          target: BookTarget.existing,
          targetBookId: sameName,
        ),
      );
      continue;
    }

    plan.add(
      BookPlanEntry(
        csvBookId: csvBookId,
        label: name,
        count: count,
        target: BookTarget.create,
        newName: name,
      ),
    );
  }
  return plan;
}
