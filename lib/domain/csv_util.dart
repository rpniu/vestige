import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/domain/record_book.dart';

/// CSV 导入/导出（纯 Dart，零依赖，可单测）。
///
/// ## 与旧格式的关系
/// 原 Kotlin / Go 版导出的是 6 列：
/// `ID,Title,Content,Tags,CreatedAt,UpdatedAt`（毫秒时间戳）。
/// v2 导出 7 列，插入了 `RecordedAt`：
/// `ID,Title,Content,Tags,RecordedAt,CreatedAt,UpdatedAt`
/// v5 再加第 8 列（时长；没记时长是空串）。列名用 `DurationSec`（**秒**），
/// 导入时兼容更早开发版用过的 `DurationMin`（分钟，自动 ×60）。
/// v8 在末尾追加第 9、10 列（记录本 id 与名字），于是「一次导出多个记录本」
/// 只产出**一个文件**：每行自己带本，导入时按行归位（见 [CsvImportResult.bookNames]）。
///
/// 导入按**表头名字**匹配列，因此：
/// - 新格式：`recordedAt` 取 RecordedAt 列；
/// - 旧格式（无 RecordedAt）：把 CreatedAt 当作业务日期（旧版语义就是如此），
///   `createdAt` 同时沿用旧值，于是旧数据不会被误标成「补记」；
/// - 没有表头的裸数据：10 列按 v8 顺序、8 列按 v5 顺序、7 列按 v2 顺序、
///   6 列按旧顺序解析；
/// - 时间值兼容「秒级时间戳」（自动 ×1000）与 ISO-8601 字符串；
/// - **没有记录本列的文件（v5 及更早）一律视为「默认记录本」的数据**，
///   而不是「导入到当前正在用的那一本」—— 旧文件里没有本的信息，
///   猜当前本会让用户在不知情的情况下把数据混进另一本。
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
    'BookId',
    'Book',
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
  /// [bookNames] 是「记录本 id → 名字」，用来填 `Book` 列。它是**可读名的唯一
  /// 来源**：id 在同库里是精确锚点，但把文件拿到另一台设备上时 id 对不上，
  /// 只能靠名字重新认领（见 [CsvImportResult.bookNames]）。缺名字时该列留空，
  /// 导入侧会退回默认记录本。
  ///
  /// [withBom] 默认 true —— 面向「导出后要拿 Excel 打开」的真实场景；
  /// 内部做纯文本比对时（例如单测）可以关掉。
  static String export(
    List<RecordEntity> records, {
    Map<String, String> bookNames = const <String, String>{},
    bool withBom = true,
  }) {
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
          _escape(r.bookId),
          _escape(bookNames[r.bookId] ?? ''),
        ].join(','),
      );
    }
    return buffer.toString();
  }

  // ── 导入 ────────────────────────────────────────────────────────────

  /// [fallbackBookId] 只对**没有记录本信息的文件**生效（v5 及更早，或用户手工
  /// 删掉了那两列）：这些行归入哪一本。默认本的语义是「升级时带过来的那份数据」，
  /// 是所有旧数据的归属地，所以缺省就是它。
  static CsvImportResult parse(
    String source, {
    String fallbackBookId = kDefaultBookId,
  }) {
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
    // CSV 里的记录本 id → 名字。只用来「在新库里认领 / 新建记录本」，
    // 本身不参与记录字段的还原。
    final bookNames = <String, String>{};
    var hasBookColumn = headIndex != null &&
        (headIndex.containsKey('BOOKID') || headIndex.containsKey('BOOK'));
    var skipped = 0;

    for (var i = 0; i < dataRows.length; i++) {
      final row = dataRows[i];
      final lineNo = headIndex == null ? i + 1 : i + 2;
      if (row.isEmpty || row.every((c) => c.trim().isEmpty)) continue;
      // 无表头的裸数据：10 列的最后一个版本才知道记录本（见类文档）
      if (headIndex == null && row.length >= 10) hasBookColumn = true;

      cell(String key, {int? fallback}) {
        final idx = headIndex != null ? headIndex[key] : fallback;
        if (idx == null || idx < 0 || idx >= row.length) return '';
        return row[idx].trim();
      }

      final content =
          _stripFormulaGuard(cell('CONTENT', fallback: headIndex == null ? 2 : null));
      final title =
          _stripFormulaGuard(cell('TITLE', fallback: headIndex == null ? 1 : null));
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

      // 记录本：缺列（v5 及更早的文件）→ 默认本。
      final rawBookId = cell(
        'BOOKID',
        fallback: headIndex == null ? (row.length >= 10 ? 8 : null) : null,
      );
      final rawBookName = _stripFormulaGuard(
        cell(
          'BOOK',
          fallback: headIndex == null ? (row.length >= 10 ? 9 : null) : null,
        ),
      );
      final bookId = rawBookId.isEmpty ? fallbackBookId : rawBookId;
      if (rawBookName.isNotEmpty) {
        bookNames.putIfAbsent(bookId, () => rawBookName);
      }

      if (content.isEmpty && title.isEmpty) {
        skipped++;
        errors.add('第 $lineNo 行：内容为空，已跳过');
        continue;
      }

      final tags = _stripFormulaGuard(
        cell('TAGS', fallback: headIndex == null ? 3 : null),
      )
          .split(tagSeparator)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      records.add(
        RecordEntity(
          bookId: bookId,
          id: _sanitizeId(rawId),
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
      bookNames: bookNames,
      hasBookColumn: hasBookColumn,
    );
  }

  // ── 内部实现 ────────────────────────────────────────────────────────

  /// 允许出现在 id（= 数据库主键 = 路由参数）里的字符集。
  ///
  /// 为什么必须收紧（2026-10-27 审查 M-004）：导入把 CSV 的 ID 列原样当主键，
  /// 而这个 id 之后会进两条路径 ——
  /// - **URL 路径**（`/edit/<id>`）：含 `/` `?` `#` 会让路由匹配失败，记录点不开；
  /// - **「新建」保留字**：编辑页用 `new` / `new@...` 表示尚未落库的新记录，
  ///   一条 id 恰好是 `new` 的记录会被当成新建入口，用户点它等于又记了一条。
  ///
  /// 不合规的 id 一律**重新生成 UUID**（而不是丢弃整行）：ID 只是幂等导入的锚点，
  /// 换一个代价是可预期的（这一行会作为新记录插入），丢一行则是数据损失。
  static final RegExp _safeIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// 编辑页里表示「新建」的保留前缀（见 `edit_record_provider.kNewRecordId`）。
  static const String _reservedNewId = 'new';

  static String _sanitizeId(String raw) {
    final id = raw.trim();
    if (id.isEmpty) return const Uuid().v4();
    if (!_safeIdPattern.hasMatch(id)) return const Uuid().v4();
    if (id == _reservedNewId || id.startsWith('$_reservedNewId@')) {
      return const Uuid().v4();
    }
    return id;
  }

  /// 首行是否像表头：必须命中**至少两个**已知列名。
  ///
  /// 只判「含 ID 或 CONTENT」会把数据行吃掉（2026-10-27 审查 m-003）：
  /// 无表头文件的正文里出现英文 `id` / `content` 时，那一行会被当表头跳过，
  /// 而且列序也被重排。要求两个列名同时命中，误判概率降到可忽略。
  static bool _looksLikeHeader(List<String> row) {
    const known = <String>{
      'ID',
      'TITLE',
      'CONTENT',
      'TAGS',
      'RECORDEDAT',
      'CREATEDAT',
      'UPDATEDAT',
      'DURATIONSEC',
      'DURATIONMIN',
      'DATE',
      'CREATETIME',
      'UPDATETIME',
      'UPDATEDDATE',
    };
    var hits = 0;
    for (final cell in row) {
      if (known.contains(_normalizeKey(cell))) {
        hits++;
        if (hits >= 2) return true;
      }
    }
    return false;
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

  /// 会被表格软件（Excel / Numbers / LibreOffice）识别成**公式**的首字符。
  ///
  /// 导出时见到这些字符必须中和（2026-10-27 审查 M-009）：CSV 是拿去 Excel 打开的，
  /// 一个以 `=` 开头的正文在那边会被求值（`=HYPERLINK(...)`、`=cmd|...`），
  /// 而本 App 的导出默认走系统分享 —— 文件是会被发出去的。
  static const String _formulaPrefixes = '=+-@\t\r';

  /// 中和公式风险：前置单引号（表格软件的「按文本处理」约定）。
  static String _guardFormula(String value) =>
      value.isNotEmpty && _formulaPrefixes.contains(value[0])
          ? "'$value"
          : value;

  /// 导入时还原 [_guardFormula] 加上的单引号 —— 保证「导出 → 导入」内容不变。
  ///
  /// 正文、标题、标签三列都要过这一步：导出侧的中和是**逐列**做的
  /// （标签列是整串拼接后再中和），漏掉任何一列，往返一次就会多出一个前导 `'`。
  static String _stripFormulaGuard(String value) =>
      value.length >= 2 &&
              value[0] == "'" &&
              _formulaPrefixes.contains(value[1])
          ? value.substring(1)
          : value;

  static String _escape(String value) {
    final guarded = _guardFormula(value);
    if (guarded.contains(',') ||
        guarded.contains('"') ||
        guarded.contains('\n') ||
        guarded.contains('\r')) {
      return '"${guarded.replaceAll('"', '""')}"';
    }
    return guarded;
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
    this.bookNames = const <String, String>{},
    this.hasBookColumn = false,
  });

  /// 解析成功的记录（尚未落库）。
  final List<RecordEntity> records;

  /// 因数据不完整被跳过的行数。
  final int skipped;

  /// 逐行错误说明（最多展示前几条）。
  final List<String> errors;

  /// 文件里出现过的记录本：id → 名字（名字可能为空串）。
  ///
  /// 导入时用它决定「归到哪一本」：id 能在本库里找到就直接归位；
  /// 找不到但名字能对上同名本，就归入同名本；都没有则按这个名字新建一本。
  final Map<String, String> bookNames;

  /// 文件是否带记录本列。
  ///
  /// false = v5 及更早的导出文件（8 列），全部归入默认记录本 ——
  /// 界面必须把这件事讲出来，否则用户在别的记录本里导入时会以为数据丢了。
  final bool hasBookColumn;

  bool get isEmpty => records.isEmpty;

  /// 其中属于「补记」的条数（导入后即可见）。
  int get backfilledCount => records.where((r) => r.isBackfilled).length;

  /// 按记录本分组：id → 条数（保持文件中首次出现的顺序）。
  Map<String, int> get bookCounts {
    final counts = <String, int>{};
    for (final r in records) {
      counts[r.bookId] = (counts[r.bookId] ?? 0) + 1;
    }
    return counts;
  }

  /// 某个记录本在预览里的称呼：有名字用名字，没有就写「默认记录本」/「未命名记录本」。
  String bookLabel(String bookId) {
    final name = bookNames[bookId] ?? '';
    if (name.isNotEmpty) return name;
    return bookId == kDefaultBookId ? '默认记录本' : '未命名记录本';
  }

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
