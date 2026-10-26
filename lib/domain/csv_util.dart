import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';

/// CSV 导入/导出（纯 Dart，零依赖，可单测）。
///
/// ## 与旧格式的关系
/// 原 Kotlin / Go 版导出的是 6 列：
/// `ID,Title,Content,Tags,CreatedAt,UpdatedAt`（毫秒时间戳）。
/// v2 导出 7 列，插入了 `RecordedAt`：
/// `ID,Title,Content,Tags,RecordedAt,CreatedAt,UpdatedAt`
/// v5 再加第 8 列（时长；没记时长是空串）。列名用 `DurationSec`（**秒**），
/// 导入时兼容更早开发版用过的 `DurationMin`（分钟，自动 ×60）。
///
/// 导入按**表头名字**匹配列，因此：
/// - 新格式：`recordedAt` 取 RecordedAt 列；
/// - 旧格式（无 RecordedAt）：把 CreatedAt 当作业务日期（旧版语义就是如此），
///   `createdAt` 同时沿用旧值，于是旧数据不会被误标成「补记」；
/// - 没有表头的裸数据：8 列按新顺序、7 列按 v2 顺序、6 列按旧顺序解析；
/// - 时间值兼容「秒级时间戳」（自动 ×1000）与 ISO-8601 字符串。
///
/// 手写解析器（而非依赖 csv 包）：字段少但要求严——必须容忍 BOM、CRLF、
/// 引号内换行、转义引号，以及上面那些历史格式，自己控制更省心。
///
/// ## 编码
/// 导出统一输出 **UTF-8 with BOM**（见 [bom]），这样在 Windows 上双击用 Excel
/// 打开不会乱码；导入时无论有没有 BOM 都能解析（会自己剥掉）。
class CsvUtil {
  const CsvUtil._();

  static const List<String> headers = <String>[
    'ID',
    'Title',
    'Content',
    'Tags',
    'RecordedAt',
    'CreatedAt',
    'UpdatedAt',
    'DurationSec',
  ];

  /// 标签在 CSV 内用 `;` 分隔（与原 Kotlin 导出一致，避免与字段逗号冲突）。
  static const String tagSeparator = ';';

  /// UTF-8 BOM（`EF BB BF`）。
  ///
  /// 导出的 CSV 一律带上它：Windows 上的 Excel 打开无 BOM 的 UTF-8 CSV 时会
  /// 按系统本地编码（中文环境是 GBK）解释，中文标题/内容直接变乱码；有了 BOM
  /// 才会正确识别为 UTF-8。其他工具（numbers、LibreOffice、pandas）也都兼容，
  /// 多出来的这三个字节对它们只是「零宽不换行空格」，解析时会被自动忽略。
  static const String bom = '\uFEFF';

  /// 把 CSV 的**字节流**解成文本。
  ///
  /// 严格 UTF-8 解不出时（例如 Windows / Excel 导出的 GBK 文件）退回**容错模式**，
  /// 并把 `false` 带出去 —— 界面要在预览里提示「编码可能不对」。
  /// 否则用户会拿到一堆乱码，却完全不知道原因，只会觉得「这 App 坏了」。
  ///
  /// 返回 `(文本, 是不是干净的 UTF-8)`。
  ///
  /// 这段逻辑原来埋在 `profile_screen` 的私有方法里（815 行的页面、零测试）。
  /// 搬到这里是因为它是纯逻辑、而且直接决定用户看到的是不是乱码 ——
  /// 值得被单测钉住。
  static (String, bool) decodeBytes(List<int> bytes) {
    try {
      return (utf8.decode(bytes), true);
    } on FormatException {
      return (utf8.decode(bytes, allowMalformed: true), false);
    }
  }

  // ── 导出 ────────────────────────────────────────────────────────────

  /// 导出为 CSV 文本。
  ///
  /// [withBom] 默认 true —— 面向「导出后要拿 Excel 打开」的真实场景；
  /// 内部做纯文本比对时（例如单测）可以关掉。
  static String export(List<RecordEntity> records, {bool withBom = true}) {
    final buffer = StringBuffer();
    if (withBom) buffer.write(bom);
    buffer.writeln(headers.join(','));
    for (final r in records) {
      buffer.writeln(
        <String>[
          _escape(r.id),
          _escape(r.title ?? ''),
          _escape(r.content),
          _escape(r.tags.join(tagSeparator)),
          r.recordedAt.millisecondsSinceEpoch.toString(),
          r.createdAt.millisecondsSinceEpoch.toString(),
          r.updatedAt.millisecondsSinceEpoch.toString(),
          r.durationS?.toString() ?? '',
        ].join(','),
      );
    }
    return buffer.toString();
  }

  // ── 导入 ────────────────────────────────────────────────────────────

  static CsvImportResult parse(String source) {
    // 剥掉 BOM。Dart 的 `utf8.decode` 本来就会吃掉文件开头的 BOM（所以从文件
    // 读进来时这里通常是空操作），但文本也可能来自剪贴板/字符串拼接，
    // 兜一层更稳，也顺带处理「有的工具重复写了两个 BOM」的情况。
    var text = source;
    while (text.startsWith(bom)) {
      text = text.substring(bom.length);
    }
    final rows = _parseRows(text);
    if (rows.isEmpty) {
      return const CsvImportResult(
        records: <RecordEntity>[],
        skipped: 0,
        errors: <String>['文件是空的'],
      );
    }

    final Map<String, int>? headIndex = _looksLikeHeader(rows.first)
        ? _indexHeader(rows.first)
        : null;
    final dataRows = headIndex == null ? rows : rows.skip(1).toList();

    final records = <RecordEntity>[];
    final errors = <String>[];
    var skipped = 0;

    for (var i = 0; i < dataRows.length; i++) {
      final row = dataRows[i];
      final lineNo = headIndex == null ? i + 1 : i + 2;
      if (row.isEmpty || row.every((c) => c.trim().isEmpty)) continue;

      cell(String key, {int? fallback}) {
        final idx = headIndex != null ? headIndex[key] : fallback;
        if (idx == null || idx < 0 || idx >= row.length) return '';
        return row[idx].trim();
      }

      final content = cell('CONTENT', fallback: headIndex == null ? 2 : null);
      final title = cell('TITLE', fallback: headIndex == null ? 1 : null);
      final rawId = cell('ID', fallback: headIndex == null ? 0 : null);

      // 时间：优先 RecordedAt，其次 CreatedAt（兼容旧格式），最后退回现在。
      final recordedRaw = cell(
        'RECORDEDAT',
        fallback: headIndex == null ? (row.length >= 7 ? 4 : null) : null,
      );
      final createdRaw = cell(
        'CREATEDAT',
        fallback: headIndex == null ? (row.length >= 7 ? 5 : 4) : null,
      );
      final updatedRaw = cell(
        'UPDATEDAT',
        fallback: headIndex == null ? (row.length >= 7 ? 6 : 5) : null,
      );
      // 时长（秒）：只有第 8 列按表头匹配，裸数据顺序不给 fallback ——
      // 旧 6/7 列的裸数据本来就没有时长。表头是 DurationMin（分钟）时 ×60。
      final durationRaw = cell('DURATIONSEC');
      final durationMinRaw = cell('DURATIONMIN');
      final int? durationS;
      if (durationRaw.isNotEmpty) {
        durationS = int.tryParse(durationRaw);
      } else {
        final asMinutes = int.tryParse(durationMinRaw);
        durationS = asMinutes == null ? null : asMinutes * 60;
      }

      final now = DateTime.now();
      final created = _parseTime(createdRaw) ?? _parseTime(recordedRaw) ?? now;
      // 旧格式没有 RecordedAt 列 → 用 createdAt 当业务日期，旧数据不标补记。
      final recorded = _parseTime(recordedRaw) ?? created;
      final updated = _parseTime(updatedRaw) ?? created;

      if (content.isEmpty && title.isEmpty) {
        skipped++;
        errors.add('第 $lineNo 行：内容为空，已跳过');
        continue;
      }

      final tags = cell('TAGS', fallback: headIndex == null ? 3 : null)
          .split(tagSeparator)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      records.add(
        RecordEntity(
          id: rawId.isEmpty ? const Uuid().v4() : rawId,
          title: title.isEmpty ? null : title,
          content: content,
          tags: tags,
          recordedAt: recorded,
          createdAt: created,
          updatedAt: updated,
          deleted: false,
          durationS: durationS,
        ),
      );
    }

    return CsvImportResult(
      records: records,
      skipped: skipped,
      errors: errors,
    );
  }

  // ── 内部实现 ────────────────────────────────────────────────────────

  static bool _looksLikeHeader(List<String> row) {
    final keys = row.map(_normalizeKey).toSet();
    return keys.contains('ID') || keys.contains('CONTENT');
  }

  static Map<String, int> _indexHeader(List<String> row) {
    final map = <String, int>{};
    for (var i = 0; i < row.length; i++) {
      final key = _normalizeKey(row[i]);
      if (key.isNotEmpty) map.putIfAbsent(key, () => i);
    }
    // 常见别名（不同的旧版本导出用过不同列名）
    map.putIfAbsent('RECORDEDAT', () => map['DATE'] ?? -1);
    map.putIfAbsent('CREATEDAT', () => map['CREATETIME'] ?? -1);
    map.putIfAbsent('UPDATEDAT', () => map['UPDATETIME'] ?? map['UPDATEDDATE'] ?? -1);
    return map;
  }

  /// `created_at` / `recorded at` → `CREATEDAT`
  static String _normalizeKey(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static DateTime? _parseTime(String raw) {
    if (raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) {
      // 小于 1e10 视为秒级时间戳（原 Go 版导出），否则按毫秒。
      final ms = asInt.abs() < 10000000000 ? asInt * 1000 : asInt;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final parsed = DateTime.tryParse(raw);
    return parsed?.toLocal();
  }

  static String _escape(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  /// 支持引号包裹、双写转义引号、引号内换行、CRLF / LF / CR。
  static List<List<String>> _parseRows(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var hasField = false;

    void endField() {
      row.add(field.toString());
      field.clear();
      hasField = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
        continue;
      }

      switch (c) {
        case '"':
          inQuotes = true;
          hasField = true;
        case ',':
          endField();
        case '\r':
          if (i + 1 < text.length && text[i + 1] == '\n') i++;
          endRow();
        case '\n':
          endRow();
        default:
          field.write(c);
          hasField = true;
      }
    }

    if (hasField || field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }
}

/// 解析结果：成功解析出的记录 + 跳过/报错信息，供 UI 提示。
class CsvImportResult {
  const CsvImportResult({
    required this.records,
    required this.skipped,
    required this.errors,
  });

  /// 解析成功的记录（尚未落库）。
  final List<RecordEntity> records;

  /// 因数据不完整被跳过的行数。
  final int skipped;

  /// 逐行错误说明（最多展示前几条）。
  final List<String> errors;

  bool get isEmpty => records.isEmpty;

  /// 其中属于「补记」的条数（导入后即可见）。
  int get backfilledCount => records.where((r) => r.isBackfilled).length;

  String summary() {
    if (records.isEmpty) {
      return skipped == 0 ? '没有可导入的数据' : '没有可导入的数据（跳过 $skipped 行）';
    }
    final buffer = StringBuffer('成功导入 ${records.length} 条');
    if (backfilledCount > 0) buffer.write('，其中补记 $backfilledCount 条');
    if (skipped > 0) buffer.write('，跳过 $skipped 行');
    return buffer.toString();
  }
}
