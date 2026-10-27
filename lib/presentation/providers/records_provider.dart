import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/domain/calendar_util.dart';
import 'package:vestige/domain/csv_util.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/providers/core_providers.dart';

/// 列表 / 统计 / 补记 / 导入导出 的状态层。
///
/// 数据源是 `dao.watchAllActive()` 的响应式流（等价原 Room 的 Flow）：
/// 任何一次写入都会自动推给 UI，不需要手动 refresh。

// ── 原始数据 ──────────────────────────────────────────────────────────

/// 全部活跃记录，按业务日期（recordedAt）倒序。
final recordsProvider = StreamProvider<List<RecordEntity>>(
  (ref) => ref.watch(recordRepositoryProvider).watchAllRecords(),
);

/// 回收站。
final trashProvider = StreamProvider<List<RecordEntity>>(
  (ref) => ref.watch(recordRepositoryProvider).watchDeletedRecords(),
);

// ── 派生数据 ──────────────────────────────────────────────────────────

/// 按「属于哪一天」分组后的列表，供首页使用。
final groupedRecordsProvider = Provider<List<RecordGroup>>((ref) {
  final records = ref.watch(recordsProvider).valueOrNull;
  if (records == null || records.isEmpty) return const <RecordGroup>[];
  return groupRecordsByDay(records);
});

/// 首页/统计页顶部用的汇总数字。
final recordStatsProvider = Provider<RecordStats>((ref) {
  final records = ref.watch(recordsProvider).valueOrNull;
  return RecordStats.from(records ?? const <RecordEntity>[]);
});

/// 首页要渲染的**扁平行**列表（分组头与卡片交错）。
///
/// 为什么值得多这一层：分组头 + 卡片如果按「一个分组 = 一个列表项」来渲染，
/// 那这一天有多少条记录，进入屏幕时就会在**同一帧**里全部构建出来。
/// 而这个 App 的核心操作是「长按 FAB 立刻记一条」，一天堆出几百条很常见，
/// 滚到那天就是一次几百张卡片的集中构建 —— 掉帧感非常明显。
/// 拍平成行之后，每张卡片都吃到 `SliverList` 的惰性构建，屏幕外的不建。
///
/// 放在 provider 里而不是在 `build` 里算：它只在分组变化（即数据写入）时重建一次，
/// 多选时每次 `setState` 都不用把这 N 行重算一遍。
///
/// 选中标签筛选时，行列表在分组之后过滤 —— 空组整组消失，分组头的
/// 「N 条 / 补记 N」跟着换成**过滤后**的那个组（否则头和卡片对不上）。
final homeRowsProvider = Provider<List<HomeRow>>((ref) {
  final groups = ref.watch(groupedRecordsProvider);
  if (groups.isEmpty) return const <HomeRow>[];
  final tags = ref.watch(effectiveTagFilterProvider);
  final rows = <HomeRow>[];
  // 无筛选是最常见的一档，提到循环外判一次：不然每条记录都要过一次
  // 「集合是不是空」的判断（几万条时这点差别也值得省）。
  if (tags.isEmpty) {
    for (final g in groups) {
      rows.add(DayHeaderRow(g));
      for (final r in g.records) {
        rows.add(RecordRow(r));
      }
    }
    return rows;
  }
  // 多选是「或」而不是「且」：勾了「咖啡」和「工作」，要的是**两类都看**。
  // 若是「且」，两个标签各自的记录几乎不会同时落在同一条上，勾第二个就等于清空列表 ——
  // 那对「挑几个标签翻一翻」这个用法是纯负担。记录多标签的设计本来就意味着
  // 这几个标签是这条记录的不同侧面，不该互相排斥。
  for (final g in groups) {
    final kept = g.records
        .where((r) => r.tags.any(tags.contains))
        .toList(growable: false);
    if (kept.isEmpty) continue;
    rows.add(
      DayHeaderRow(
        RecordGroup(dayNumber: g.dayNumber, key: g.key, records: kept),
      ),
    );
    for (final r in kept) {
      rows.add(RecordRow(r));
    }
  }
  return rows;
});

// ── 标签筛选 ──────────────────────────────────────────────────────────

/// 全部标签及各自的条数，按条数降序（同数按名称），供首页过滤栏使用。
final tagCountsProvider = Provider<List<({String tag, int count})>>((ref) {
  final records = ref.watch(recordsProvider).valueOrNull;
  if (records == null) return const <({String tag, int count})>[];
  final counts = <String, int>{};
  for (final r in records) {
    for (final t in r.tags) {
      final seen = counts[t];
      counts[t] = seen == null ? 1 : seen + 1;
    }
  }
  final list = counts.entries
      .map((e) => (tag: e.key, count: e.value))
      .toList()
    ..sort(
      (a, b) =>
          b.count != a.count ? b.count.compareTo(a.count) : a.tag.compareTo(b.tag),
    );
  return list;
});

/// 首页当前勾选的标签，空集 = 不筛选。
///
/// 用 `Set` 而不是 `List`：勾选/取消是「某个标签在不在里面」的判定，
/// 过滤时每条记录都要问一次（`tags.any(selected.contains)`），
/// `contains` 走哈希是 O(1)，换成 List 就退化成 O(勾选数)。
final selectedTagsProvider =
    NotifierProvider<SelectedTagsController, Set<String>>(
  SelectedTagsController.new,
);

class SelectedTagsController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// 勾上/取消一个标签；其它已勾的**不受影响**（这就是复选与单选的差别）。
  void toggle(String tag) {
    final next = Set<String>.of(state);
    if (!next.remove(tag)) next.add(tag);
    state = next;
  }

  /// 全选：把 [tags] 里所有标签都勾上（与已有的勾选合并，不是替换）。
  ///
  /// 为什么不直接 `state = tags.toSet()`：调用方传进来的通常是**当前可见的全部标签**，
  /// 而用户此前勾过的标签本来就含在这个集合里，合并与替换结果相同；
  /// 但万一调用方只拿到一个子集（比如将来做「只全选某分类」），
  /// 替换式会把用户勾好的其他标签**悄悄抹掉**。合并语义更安全。
  void selectAll(Iterable<String> tags) =>
      state = <String>{...state, ...tags};

  void clear() => state = const <String>{};
}

/// 标签弹层当前是否开着。
///
/// 为什么这个也要进 provider：标题栏那个入口按钮（[AppBar.actions]）
/// 和弹层本身是两个不同层的 widget —— 首页 body 里的东西刷不动 AppBar。
/// 有了它，按钮能跟着弹层开合换图标/选中态（弹层开着时按钮是亮的）。
final tagSheetOpenProvider = StateProvider<bool>((ref) => false);

/// 实际生效的标签筛选：勾中的标签可能刚随记录一起被删掉，
/// 失效的那些直接剔掉（全失效 = 无筛选），免得用户对着一个空列表找不到北。
///
/// 公开（无下划线）：首页要拿它来渲染指示条上的标签名与实际条数，
/// 而这两个数必须和列表用的是同一份口径 —— 在页面里再算一遍迟早对不上。
final effectiveTagFilterProvider = Provider<Set<String>>((ref) {
  final selected = ref.watch(selectedTagsProvider);
  if (selected.isEmpty) return const <String>{};
  final counts = ref.watch(tagCountsProvider);
  return selected.where((t) => counts.any((c) => c.tag == t)).toSet();
});

/// 当前筛选命中的**总条数**（跨所有日期）。
///
/// 注意它不等于列表里可见卡片数之和之外的任何东西 —— 就是「这些标签一共能看见几条」，
/// 指示条上的「N 条」读它。以前是取某个标签的 `tagCounts` 条数，
/// 单选时那恰好等于命中总数；复选后必须按「并集」重算。
final filteredRecordCountProvider = Provider<int>((ref) {
  final tags = ref.watch(effectiveTagFilterProvider);
  if (tags.isEmpty) return ref.watch(recordStatsProvider).totalCount;
  final records = ref.watch(recordsProvider).valueOrNull;
  if (records == null) return 0;
  var n = 0;
  for (final r in records) {
    if (r.tags.any(tags.contains)) n++;
  }
  return n;
});

/// 首页列表里的一行。
sealed class HomeRow {
  const HomeRow();
}

/// 日期分组头这一行。
final class DayHeaderRow extends HomeRow {
  const DayHeaderRow(this.group);

  final RecordGroup group;
}

/// 一条记录卡片这一行。
final class RecordRow extends HomeRow {
  const RecordRow(this.record);

  final RecordEntity record;
}

/// 最近一次「记了点什么」是哪天 —— 最新那个分组的天数序号；一条记录都没有时为 null。
///
/// 用途：主页标题那句「距上次记录 N 天」。
///
/// 取的是 [groupedRecordsProvider] 的第一个分组，而不是 `records.first`：
/// 分组在 [groupRecordsByDay] 里已经按天数序号倒序排过，不依赖 DAO 的 ORDER BY ——
/// 哪天查询换了排序，这里也不会悄悄算错。
///
/// 返回**整数天数序号**而不是 `DateTime`：主页每次构建都要读它，
/// 而 `DateTime(y, m, d)` 是「向系统问时区」（约 23µs，见 day_util 的说明）。
final lastRecordedDayProvider = Provider<int?>((ref) {
  final groups = ref.watch(groupedRecordsProvider);
  return groups.isEmpty ? null : groups.first.dayNumber;
});

/// 有记录的年份（含今年），倒序，供统计页年份下拉使用。
final availableYearsProvider = Provider<List<int>>((ref) {
  final records = ref.watch(recordsProvider).valueOrNull;
  final years = <int>{DateTime.now().year};
  if (records != null) {
    for (final r in records) {
      years.add(r.recordedAt.year);
    }
  }
  return years.toList()..sort((a, b) => b.compareTo(a));
});

/// 每一年的**记录总条数**（key = 年份）。
///
/// 年份弹层里每行末尾那个数字，以及「月度分布」卡副标题上的当年合计，都读它。
/// 口径和 [availableYearsProvider] 完全一致：只看 [RecordEntity.recordedAt] 的年份，
/// 补记算进它真正归属的那一年 —— 换一年就是一年的数，不跟「哪年导入的」走。
///
/// 注意：这里统计的是**全部**年份，不是某一年。因此不要把它放进
/// [monthlyStatsProvider] 那种「跟着选中年份算」的 provider 里，
/// 否则弹层一打开就得先切年份才能看到其他年份有多少条。
final yearTotalsProvider = Provider<Map<int, int>>((ref) {
  final records = ref.watch(recordsProvider).valueOrNull;
  final totals = <int, int>{};
  if (records == null) return totals;
  for (final r in records) {
    final year = r.recordedAt.year;
    final seen = totals[year];
    // 显式判空而不是 `update(year, (v) => v + 1)`：后者每条记录都要分配一个闭包，
    // 这里的数据量不大，但既然分组那边已经是这个写法，保持一致。
    totals[year] = seen == null ? 1 : seen + 1;
  }
  return totals;
});

/// 统计页当前选中的年份。
final selectedYearProvider =
    NotifierProvider<SelectedYearController, int>(SelectedYearController.new);

class SelectedYearController extends Notifier<int> {
  @override
  int build() => DateTime.now().year;

  void select(int year) => state = year;
}

/// 统计页**真正在展示**的年份。
///
/// [selectedYearProvider] 里那个年份可能已经从 [availableYearsProvider] 里消失了
/// （选了 2020，随后把 2020 的记录全删了）。以前年份药丸会退回最新的一年、
/// 而柱状图还按 2020 画 —— 药丸写着 2026，图里全是 0。
/// 「退到哪一年」这件事现在只在这里判定一次，药丸、柱图、当年的合计都读它，
/// 三者不可能再各说各话。
final shownYearProvider = Provider<int>((ref) {
  final years = ref.watch(availableYearsProvider);
  final selected = ref.watch(selectedYearProvider);
  return years.contains(selected) ? selected : years.first;
});

/// 选中年份的逐月统计（1–12 月，含补记条数）。
final monthlyStatsProvider = Provider<List<MonthStat>>((ref) {
  // 读 [shownYearProvider] 而不是 selectedYearProvider：年份的解读只有一处，
  // 免得药丸已经退回 2026、柱图还在画 2020。
  final year = ref.watch(shownYearProvider);
  final records = ref.watch(recordsProvider).valueOrNull;
  if (records == null) return List<MonthStat>.generate(12, MonthStat.empty);

  final counts = List<int>.filled(12, 0);
  final backfilled = List<int>.filled(12, 0);
  for (final r in records) {
    if (r.recordedAt.year != year) continue;
    final m = r.recordedAt.month - 1;
    counts[m]++;
    if (r.isBackfilled) backfilled[m]++;
  }
  return List<MonthStat>.generate(
    12,
    (i) => MonthStat(month: i + 1, count: counts[i], backfilled: backfilled[i]),
  );
});

/// 统计页「标签分布」：**选中年份**里各标签被用到的次数，按次数降序（同数按名称）。
///
/// 与 [tagCountsProvider] 的区别：那个是**全时段**的，给首页筛选弹层用；
/// 这个是**跟着统计页的年份走**的，口径与 [monthlyStatsProvider] 一致 ——
/// 只看 `recordedAt` 的年份，补记算进它真正归属的那一年。
///
/// 一条记录带多个标签就**每个标签各记一次**：这里数的是「标签被用了多少次」，
/// 不是「多少条记录带标签」。所以各项相加**不等于**该年总条数，
/// 界面上也就不能拿它去算「占比」——只能比大小。
final tagStatsProvider = Provider<List<({String tag, int count})>>((ref) {
  final year = ref.watch(shownYearProvider);
  final records = ref.watch(recordsProvider).valueOrNull;
  if (records == null) return const <({String tag, int count})>[];

  final counts = <String, int>{};
  for (final r in records) {
    if (r.recordedAt.year != year) continue;
    for (final t in r.tags) {
      final seen = counts[t];
      counts[t] = seen == null ? 1 : seen + 1;
    }
  }
  return counts.entries
      .map((e) => (tag: e.key, count: e.value))
      .toList()
    ..sort(
      (a, b) => b.count != a.count
          ? b.count.compareTo(a.count)
          : a.tag.compareTo(b.tag),
    );
});

/// 最近 [days] 天的逐日走势（含补记拆分）。
///
/// 窗口长度由 [insightWindowProvider] 决定 —— 它原来挂在（已删掉的）折线图
/// 右上角，图没了之后被硬编码成 30 天。
final dailySeriesProvider = Provider.family<List<DayStat>, int>((ref, days) {
  final records = ref.watch(recordsProvider).valueOrNull ?? const <RecordEntity>[];
  return buildDailySeries(records, days);
});

/// 洞察卡可选的窗口长度（天）。
///
/// 7 / 30 / 90 这三档是原来折线图右上角那套选择器留下的；图删掉之后这个值
/// 被硬编码成 30，等于顺手把「换个尺度看习惯」的能力也删了。现在挂在
/// 洞察卡标题右边 —— 那句「近 N 天共 X 条…」正是它控制的。
const List<int> kInsightWindowOptions = <int>[7, 30, 90];

/// 默认窗口。与当初硬编码的值保持一致，老用户不会觉得数字突然变了。
const int kDefaultInsightWindowDays = 30;

/// 洞察卡的窗口长度。
///
/// 放 provider 而不是页面 state：跨 tab 切换要保留，而且
/// [dailySeriesProvider] 是按它算的 —— 放页面里就得多传一层参数。
final insightWindowProvider = NotifierProvider<InsightWindowController, int>(
  InsightWindowController.new,
);

class InsightWindowController extends Notifier<int> {
  @override
  int build() => kDefaultInsightWindowDays;

  void select(int days) => state = days;
}

// ── 统计页「记录日历」 ────────────────────────────────────────────────

/// 日历卡当前展示的月份。
final calendarMonthProvider =
    NotifierProvider<CalendarMonthController, ({int year, int month})>(
  CalendarMonthController.new,
);

class CalendarMonthController extends Notifier<({int year, int month})> {
  @override
  ({int year, int month}) build() {
    final now = DateTime.now();
    return (year: now.year, month: now.month);
  }

  /// 前后翻月（[deltaMonths] 一般是 ±1）。
  void shift(int deltaMonths) {
    final total = state.year * 12 + (state.month - 1) + deltaMonths;
    state = (year: total ~/ 12, month: total % 12 + 1);
  }
}

/// 展示月份的逐日统计（**日号** → 条数 / 补记数）。
/// 口径与其他统计一致：一律按业务日期 recordedAt。
final calendarStatsProvider = Provider<Map<int, CalendarDayStat>>((ref) {
  final shown = ref.watch(calendarMonthProvider);
  final records = ref.watch(recordsProvider).valueOrNull;
  final stats = <int, CalendarDayStat>{};
  if (records == null) return stats;
  for (final r in records) {
    if (r.recordedAt.year != shown.year ||
        r.recordedAt.month != shown.month) {
      continue;
    }
    final d = r.recordedAt.day;
    final prev = stats[d];
    stats[d] = CalendarDayStat(
      count: (prev?.count ?? 0) + 1,
      backfilled: (prev?.backfilled ?? 0) + (r.isBackfilled ? 1 : 0),
    );
  }
  return stats;
});

/// 逐日走势：把「落在同一天」的记录归类到该天（补记也会算进归属日）。
List<DayStat> buildDailySeries(
  List<RecordEntity> records,
  int days, {
  DateTime? now,
}) {
  final window = lastNDays(days, now: now);
  // 窗口外的记录直接跳过：以前是先把**所有**记录按天建桶、再只取窗口内那几天，
  // 几万条数据里 99% 的桶建完就扔。一次 isBefore 比较（~0.02 µs）换掉一次
  // 字符串拼接 + 哈希插入，是最划算的一刀。
  final from = window.first;
  final buckets = <String, List<RecordEntity>>{};
  for (final r in records) {
    if (r.recordedAt.isBefore(from)) continue;
    buckets.putIfAbsent(r.recordedDayKey, () => <RecordEntity>[]).add(r);
  }
  return window
      .map(
        (day) => DayStat(
          day: day,
          records: buckets[dayKey(day)] ?? const <RecordEntity>[],
        ),
      )
      .toList();
}

/// 把扁平记录按「归属日」聚成首页要用的分组：日期倒序，组内按业务时刻倒序。
///
/// 公开而非私有：它是首页唯一的重活，也是基准测试（`test/perf/`）的观测点，
/// 藏在 provider 文件里就只能靠肉眼估耗时了。
///
/// 分组键用 [dayNumber] 整数而非 `yyyy-MM-dd` 字符串：既省掉每条记录一次字符串拼接，
/// 也免了为每个分组构造一次本地午夜（分组数 = 有记录的天数，可能上千）。
List<RecordGroup> groupRecordsByDay(List<RecordEntity> records) {
  final map = <int, List<RecordEntity>>{};
  for (final r in records) {
    // 不用 `map.putIfAbsent(k, () => [...])`：那句每次迭代都要分配一个闭包，
    // 几万条记录就是几万个短命闭包。显式判空省掉这笔分配。
    final n = dayNumber(r.recordedAt);
    final bucket = map[n];
    if (bucket == null) {
      map[n] = <RecordEntity>[r];
    } else {
      bucket.add(r);
    }
  }
  final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
  return keys.map((n) {
    final bucket = map[n]!
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    return RecordGroup(
      dayNumber: n,
      key: dayKey(bucket.first.recordedAt),
      records: bucket,
    );
  }).toList();
}

// ── 写入动作 ──────────────────────────────────────────────────────────

/// 写操作集合。UI 里 `ref.read(recordActionsProvider).xxx()` 即可。
final recordActionsProvider = Provider<RecordActions>(
  (ref) => RecordActions(ref.watch(recordRepositoryProvider)),
);

class RecordActions {
  RecordActions(this._repo);

  final RecordRepository _repo;

  /// 最近一次可撤销操作**实际写下的** undo 条目 id。
  ///
  /// 为什么需要它（2026-10-27 审查 M-007）：快照为空时 `pushUndo` 不记历史，
  /// 而 UI 的「撤销」按钮原先是「回退历史里最新的一步」—— 那种情况下会退掉
  /// **上一个不相关的操作**。有了这个值，UI 可以先问「刚才真的记下了吗」，
  /// 并按 id 精确回退。
  ///
  /// null = 最近一次操作没有产生可回退的历史。
  int? lastUndoEntryId;

  /// 立刻记一笔「今天」——首页一键记录用。
  /// [content] 缺省 `1`，沿用原 App「敲一下就是一次」的习惯。
  ///
  /// 返回新记录的 id（2026-10-27 审查 C-003）：调用方（速记）据此精确撤销，
  /// 不必再靠「今天 + 最近入库」反查。id 在插入前生成，落库与返回必然是同一行。
  Future<String> quickAddToday({String content = '1', DateTime? now}) async {
    final id = const Uuid().v4();
    await _repo.addRecord(
      id: id,
      content: content,
      recordedAt: now ?? DateTime.now(),
    );
    return id;
  }

  // ── 可撤销的写操作 ──────────────────────────────────────────────────
  //
  // 全部走 [_undoable]：它保证「先存快照、再改数据」。新增批量操作时只要走它，
  // 撤销就自动有了 —— 不需要每个操作各自记得存快照，忘一个就是一个不可逆的坑。

  Future<void> deleteRecords(List<String> ids) =>
      _undoable('移入回收站', ids, () => _repo.deleteRecords(ids));

  Future<void> deleteRecord(String id) =>
      _undoable('移入回收站', <String>[id], () => _repo.deleteRecord(id));

  /// 恢复**不记历史**：它不是破坏性操作，再删一次就行，记下来只会把列表撑满。
  Future<void> restoreRecords(List<String> ids) => _repo.restoreRecords(ids);

  Future<void> hardDeleteRecords(List<String> ids) =>
      _undoable('彻底删除', ids, () => _repo.hardDeleteRecords(ids));

  Future<int> emptyTrash() async {
    lastUndoEntryId = null;
    // 清空回收站没有 id 参数，快照要自己取（整个回收站）。
    // 快照读取、清空、写历史三步放进同一事务（2026-10-27 审查 M-006）：
    // 否则「已清空但历史没写进去」会让这次操作永久不可撤销。
    return _repo.transaction(() async {
      final before = await _repo.getDeletedRecords();
      final count = await _repo.emptyTrash();
      lastUndoEntryId = await _repo.pushUndo('清空回收站', before);
      return count;
    });
  }

  /// 把选中记录整体前移/后移一天（多选补记的批量修正）。
  Future<void> shiftDay(List<String> ids, int deltaDays) => _undoable(
        deltaDays > 0 ? '日期后移 1 天' : '日期前移 1 天',
        ids,
        () => _repo.shiftRecordedAt(ids, Duration(days: deltaDays)),
      );

  /// 批量打标签 / 去标签。返回真正被改动的条数。
  Future<int> applyTags(
    List<String> ids, {
    List<String> add = const <String>[],
    List<String> remove = const <String>[],
  }) =>
      _undoable(
        '批量改标签',
        ids,
        () => _repo.applyTags(ids, add: add, remove: remove),
        // 一条都没改动时不记历史（见 _undoable 里的同一条说明）
        shouldKeep: (int changed) => changed > 0,
      );

  /// 执行一个可撤销的批量操作。
  ///
  /// 快照必须在 `action()` **之前**取 —— 操作跑完再取，拿到的就已经是
  /// 「改完之后的状态」，撤销等于没撤。
  ///
  /// 三步（读快照 → 执行 → 写历史）包在**同一个事务**里（2026-10-27 审查 M-006）：
  /// 原先各自独立提交，「数据已改、历史没写」的中间态会让这次操作永久不可撤销。
  Future<T> _undoable<T>(
    String label,
    List<String> ids,
    Future<T> Function() action, {
    bool Function(T result)? shouldKeep,
  }) async {
    lastUndoEntryId = null;
    return _repo.transaction(() async {
      final before = await _repo.getRecordsByIds(ids);
      final result = await action();
      // 一条都没改动时不记历史：留一条「撤销了也没有变化」的条目只会干扰列表
      if (shouldKeep == null || shouldKeep(result)) {
        lastUndoEntryId = await _repo.pushUndo(label, before);
      }
      return result;
    });
  }

  // ── 撤销 ────────────────────────────────────────────────────────────

  /// 最近的撤销历史（新的在前）。
  Future<List<UndoEntryEntity>> recentUndo() => _repo.recentUndo();

  /// 撤销到 [entryId] 这一步**之前** —— 它自己以及比它更新的步骤一起回滚。
  /// 返回真正被写回的记录条数。
  Future<int> undoUpTo(int entryId) => _repo.undoUpTo(entryId);

  /// 删除单条 / 清空撤销历史：只动回退点，不动记录数据。
  /// 「删历史」本身不记进历史 —— 它没有可回滚的内容。
  Future<void> deleteUndoEntry(int entryId) => _repo.deleteUndoEntry(entryId);

  Future<int> clearUndoHistory() => _repo.clearUndoHistory();

  /// 导出为 CSV 文本（含记录日期与入库时间）。
  Future<String> exportCsv() async {
    final all = await _repo.getAllActiveRecordsSync();
    return CsvUtil.export(all);
  }

  /// 落库已解析好的记录（导入用）。解析在 `domain/csv_util.dart`，
  /// UI 可以先解析、预览给用户确认，再调用这里写入。
  ///
  /// **导入是可撤销的**（2026-10-27 审查 C-002）：同 id 的行会整行覆盖既有记录，
  /// 这是本 App 唯一「既破坏又批量」的入口，没有快照就等于给用户留了一个
  /// 无法挽回的坑。快照按「将被覆盖的那些 id」取，动作与写历史同事务。
  Future<int> importRecords(List<RecordEntity> records) async {
    lastUndoEntryId = null;
    if (records.isEmpty) return 0;
    final ids = <String>[for (final r in records) r.id];
    return _repo.transaction(() async {
      final before = await _repo.getRecordsByIds(ids);
      final count = await _repo.upsertRecords(records);
      lastUndoEntryId = await _repo.pushUndo('CSV 导入', before);
      return count;
    });
  }
}

// ── 视图模型 ──────────────────────────────────────────────────────────

/// 首页的分组卡片。
class RecordGroup {
  const RecordGroup({
    required this.dayNumber,
    required this.key,
    required this.records,
  });

  /// 该组归属日在日历上的连续序号（见 [dayNumber]）。
  ///
  /// 分组头、日期比较全走它 —— 纯整数，不构造 [DateTime]。
  final int dayNumber;

  /// `yyyy-MM-dd`。
  final String key;

  final List<RecordEntity> records;

  /// 该组归属的日期（00:00）。
  ///
  /// **按需构造**：`DateTime(y, m, d)` 是「向系统问时区」的操作（实测约 23 µs），
  /// 而分组数可能上千，所以不在分组时预生成；列表分组头走
  /// [groupHeaderLabelOf] 直接吃 [dayNumber]，压根不会碰这个 getter。
  DateTime get day => records.first.recordedDay;

  int get count => records.length;

  /// 这一组里有多少条是补记的。
  int get backfilledCount => records.where((r) => r.isBackfilled).length;
}

class RecordStats {
  const RecordStats({
    required this.totalCount,
    required this.todayCount,
    required this.weekCount,
    required this.activeDays,
    required this.streak,
    required this.backfilledCount,
    required this.maxBackfillDelay,
  });

  factory RecordStats.from(List<RecordEntity> records, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    // 循环外先算一次「今天是哪天」，循环里一律用整数比较
    final refNumber = dayNumber(ref);
    var today = 0;
    var week = 0;
    var backfilled = 0;
    var maxDelay = 0;
    final days = <int>{};

    for (final r in records) {
      final number = dayNumber(r.recordedAt);
      if (number == refNumber) today++;
      if (refNumber - number <= 6 && !r.recordedAt.isAfter(ref)) week++;
      if (r.isBackfilled) {
        backfilled++;
        if (r.backfillDelayDays > maxDelay) maxDelay = r.backfillDelayDays;
      }
      days.add(number);
    }

    return RecordStats(
      totalCount: records.length,
      todayCount: today,
      weekCount: week,
      activeDays: days.length,
      streak: streakDays(records.map((r) => r.recordedAt), now: ref),
      backfilledCount: backfilled,
      maxBackfillDelay: maxDelay,
    );
  }

  /// 记录总条数。
  final int totalCount;

  /// 今天已经记了几条。
  final int todayCount;

  /// 最近 7 天（含今天）记了几条。
  final int weekCount;

  /// 有记录的天数。
  final int activeDays;

  /// 连续记录天数。
  final int streak;

  /// 补记条数。
  final int backfilledCount;

  /// 最长一次补记隔了多少天。
  final int maxBackfillDelay;
}

/// 某一年的某个月。
class MonthStat {
  const MonthStat({
    required this.month,
    required this.count,
    required this.backfilled,
  });

  const MonthStat.empty(this.month)
      : count = 0,
        backfilled = 0;

  /// 1–12。
  final int month;
  final int count;

  /// 其中补记的条数。
  final int backfilled;

  String get label => '$month月';
}

/// 某一天。
class DayStat {
  const DayStat({required this.day, required this.records});

  final DateTime day;
  final List<RecordEntity> records;

  int get count => records.length;
  int get backfilled => records.where((r) => r.isBackfilled).length;
  String get label => '${day.month}/${day.day}';
}
