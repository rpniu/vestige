/// 日期工具（纯 Dart，零依赖，可单测）。
///
/// 本文件是「补记」能力的时间语义中心：
/// 全应用一律用**本地日历日**判定「哪一天」，不用 UTC、不用毫秒差，
/// 免得跨时区/夏令时把昨天的记录算成今天。
library;

import 'package:vestige/data/database/app_database.dart';

// ── 基础 ──────────────────────────────────────────────────────────────

/// 当天 00:00:00.000（本地时区）。
///
/// **性能注意**：`DateTime(y, m, d)` 构造本地时间需要向操作系统查询时区，
/// 实测约 **23 µs/次**（Windows 桌面 JIT），比它内部那几个整数运算贵三个数量级。
/// 所以**只在真的要一个 DateTime 时调它**（比如给 UI 显示、给图表当 X 轴）；
/// 凡是只为了「比较两天是不是同一天 / 差几天」，一律走 [dayNumber] 的整数运算。
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// 次日 00:00:00.000（本地时区）。
DateTime nextDayStart(DateTime d) => DateTime(d.year, d.month, d.day + 1);

/// 本地日历日 → **连续天数序号**（1970-01-01 记作 0，可正可负）。
///
/// 纯整数运算，不构造 [DateTime]、不查时区（实测 ~0.05 µs/次，比 [dayStart] 快约 500 倍）。
/// 用它替代「`dayStart(a).difference(dayStart(b)).inDays`」这类写法。
///
/// 算法是 Howard Hinnant 的 `days_from_civil`（前推格里高利历精确解），
/// 与我们用到的 [DateTime] 日历语义完全一致（含闰年、百年/四百年规则）。
///
/// 顺带修掉一个旧实现的隐患：`dayStart` 之间的 `difference().inDays` 在
/// **有夏令时的时区**里，跨切换日两端的本地午夜只差 23 或 25 小时，
/// `inDays` 会截断成 0（把隔天算成同一天）。整数序号没有这个偏差。
/// 中国自 1991 年起无夏令时，所以这是「更快且更稳」，不是在改行为。
int dayNumber(DateTime d) => _daysFromCivil(d.year, d.month, d.day);

/// 前推格里高利历 `y-m-d` → 距 1970-01-01 的天数。
int _daysFromCivil(int y, int m, int d) {
  // 把 1/2 月挪到上一年的年末，让闰日落在「年」的末尾，消掉所有闰年特判。
  final year = m <= 2 ? y - 1 : y;
  final era = (year >= 0 ? year : year - 399) ~/ 400;
  final yoe = year - era * 400; // [0, 399]
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1; // [0, 365]
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy; // [0, 146096]
  return era * 146097 + doe - 719468;
}

/// `yyyy-MM-dd`，用作「天」的分组键与聚合键。
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [dayNumber] 的逆运算：天数序号 → 年月日。
/// 同样纯整数，不构造 [DateTime]（Hinnant 的 `civil_from_days`）。
({int year, int month, int day}) civilFromDayNumber(int z) {
  final zz = z + 719468;
  final era = (zz >= 0 ? zz : zz - 146096) ~/ 146097;
  final doe = zz - era * 146097; // [0, 146096]
  final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
  final y = yoe + era * 400;
  final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100); // [0, 365]
  final mp = (5 * doy + 2) ~/ 153; // [0, 11]
  final day = doy - (153 * mp + 2) ~/ 5 + 1; // [1, 31]
  final month = mp + (mp < 10 ? 3 : -9); // [1, 12]
  return (year: month <= 2 ? y + 1 : y, month: month, day: day);
}

/// 天数序号 → 星期（周一=1 … 周日=7）。
///
/// 1970-01-01（序号 0）是周四，故偏移 3；再取正模，负序号也不会算错。
int _weekdayOfDayNumber(int n) => ((n + 3) % 7 + 7) % 7 + 1;

/// `HH:mm`。
String timeLabel(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

/// `yyyy-MM-dd HH:mm`。
String dateTimeLabel(DateTime d) => '${dayKey(d)} ${timeLabel(d)}';

/// 是否同一天（本地日历日）。
///
/// 直接比 y/m/d 字段，不走 [dayKey] 的字符串拼接 —— 语义完全等价，但每次省掉
/// 3 次 `toString` + 2 次 `padLeft` + 1 次拼接。这条路径在统计里是 **每条记录** 都过的。
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 日历日差：`b - a` 的天数（按**本地日历日**算，不受时刻影响）。
///
/// 用 [dayNumber] 的整数差，不再构造两个本地午夜。实测 46.9 µs → 0.1 µs。
int dayDiff(DateTime a, DateTime b) => dayNumber(b) - dayNumber(a);

/// 周一=1 … 周日=7。
int weekdayIndex(DateTime d) => d.weekday;

const List<String> _weekdayNames = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

/// `周一` … `周日`。
String weekdayLabel(DateTime d) => _weekdayNames[d.weekday - 1];

/// 「今天 / 昨天 / 前天 / 更早」的友好标签，入参为 [dayNumber]。
///
/// 这是列表实际走的那条路：全程整数运算，**一次 [DateTime] 都不构造**。
/// [todayNumber] 由调用方算一次传进来，避免每条记录都重新取一次「今天」。
String friendlyDayLabelOf(int number, {required int todayNumber}) {
  switch (todayNumber - number) {
    case 0:
      return '今天';
    case 1:
      return '昨天';
    case 2:
      return '前天';
    case -1:
      return '明天';
  }
  final d = civilFromDayNumber(number);
  return d.year == civilFromDayNumber(todayNumber).year
      ? '${d.month}月${d.day}日'
      : '${d.year}年${d.month}月${d.day}日';
}

/// 「今天 / 昨天 / 前天 / 更早」的友好标签，用于列表分组头。
///
/// [now] 可注入，方便单测与预览。
String friendlyDayLabel(DateTime d, {DateTime? now}) => friendlyDayLabelOf(
      dayNumber(d),
      todayNumber: dayNumber(now ?? DateTime.now()),
    );

/// 分组头完整写法：`今天 · 9月15日 周二`。入参为 [dayNumber]。
String groupHeaderLabelOf(int number, {required int todayNumber}) {
  final friendly = friendlyDayLabelOf(number, todayNumber: todayNumber);
  final d = civilFromDayNumber(number);
  final md = '${d.month}月${d.day}日';
  final wd = _weekdayNames[_weekdayOfDayNumber(number) - 1];
  if (friendly == md) return '$md $wd';
  return '$friendly · $md $wd';
}

/// 分组头完整写法：`今天 · 9月15日 周二`。
String groupHeaderLabel(DateTime d, {DateTime? now}) => groupHeaderLabelOf(
      dayNumber(d),
      todayNumber: dayNumber(now ?? DateTime.now()),
    );

/// `2026年9月17日 周四` —— 主页标题用的「今天是哪天」完整写法。
///
/// 和 [groupHeaderLabel] 的区别：分组头是**相对今天**的（今天/昨天/前天），
/// 标题这里要的是**确定的日期本身**，所以带年份、不写「今天」。
String fullDateLabel(DateTime d) =>
    '${d.year}年${d.month}月${d.day}日 ${weekdayLabel(d)}';

/// 「距离上次记录」的那句话。[gapDays] = 今天 − 最近一次有记录的那天（整数天数序号之差）：
///
/// - `null`：一条记录都没有；
/// - `<= 0`：最近一次就是今天（万一记录被填成未来的日期，也按「今天已记录」算，不显示负数）；
/// - `1` 起：距上次记录 N 天。
String lastRecordGapLabel(int? gapDays) {
  if (gapDays == null) return '还没有记录';
  if (gapDays <= 0) return '今天已记录';
  return '距上次记录 $gapDays 天';
}

/// 最近 [days] 天的日期起点列表，从最早到今天（折线图 X 轴用）。
List<DateTime> lastNDays(int days, {DateTime? now}) {
  final today = dayStart(now ?? DateTime.now());
  final safe = days < 1 ? 1 : days;
  return List<DateTime>.generate(
    safe,
    (i) => DateTime(today.year, today.month, today.day - (safe - 1 - i)),
  );
}

// ── 键盘输入：年月日时分的合并 / 收尾 ──────────────────────────────────
// 2026-09-17 编辑页删掉了年月日 / 时分的数字框，这两个函数目前没有 UI 调用方；
// 保留是因为它们是纯函数、有完整单测，将来若要再加「直接敲」的入口可直接复用。

/// 年份可接受的范围（键盘输入框的边界）。
const int minSupportedYear = 1900;
const int maxSupportedYear = 2999;

/// 把「年 / 月 / 日 / 时 / 分」五个数字合并成一个时间。
/// 任一为空、越界或日期不存在（如 2 月 30 日）都返回 null —— 绝不悄悄进位到下个月。
DateTime? composeDateTime({
  required int? year,
  required int? month,
  required int? day,
  required int? hour,
  required int? minute,
}) {
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null) {
    return null;
  }
  if (year < minSupportedYear || year > maxSupportedYear) return null;
  if (month < 1 || month > 12) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  if (day < 1 || day > lastDayOfMonth(year, month)) return null;
  return DateTime(year, month, day, hour, minute);
}

/// 收尾用：把越界的分量夹到合法范围（月 1–12、日不超过当月最后一天、时 0–23、分 0–59），
/// 永远返回一个可用时间。用户在输入框里敲了 13 月、32 日、25 时，失焦时就按这个规则修正。
DateTime clampDateTime({
  required int year,
  required int month,
  required int day,
  required int hour,
  required int minute,
}) {
  final y = year.clamp(minSupportedYear, maxSupportedYear);
  final mo = month.clamp(1, 12);
  return DateTime(
    y,
    mo,
    day.clamp(1, lastDayOfMonth(y, mo)),
    hour.clamp(0, 23),
    minute.clamp(0, 59),
  );
}

/// 某年某月有多少天（month 传 1–12）。
int lastDayOfMonth(int year, int month) => DateTime(year, month + 1, 0).day;

// ── 连续记录天数 ──────────────────────────────────────────────────────

/// 连续记录天数：以「今天」或「昨天」为终点往回数。
///
/// 之所以允许从昨天起算，是因为今天还没记不算断签——否则早上打开 App 就会
/// 看到连续天数归零，体验很糟。今天已经记了则从今天起算。
int streakDays(Iterable<DateTime> recordedTimes, {DateTime? now}) {
  // 用天数序号（int）做集合，而不是 dayStart 出来的 DateTime：
  // 后者每条记录要付一次本地时间构造（实测 23 µs），几万条就是几百毫秒。
  final days = <int>{};
  for (final t in recordedTimes) {
    days.add(dayNumber(t));
  }
  if (days.isEmpty) return 0;

  final today = dayNumber(now ?? DateTime.now());
  var cursor = today;
  if (!days.contains(cursor)) {
    cursor = today - 1; // 今天还没记不算断签
    if (!days.contains(cursor)) return 0;
  }

  var streak = 0;
  while (days.contains(cursor)) {
    streak++;
    cursor--;
  }
  return streak;
}

// ── 记录实体上的便捷判断 ──────────────────────────────────────────────

extension RecordEntityDateX on RecordEntity {
  /// 业务日期所在天的 00:00。
  DateTime get recordedDay => dayStart(recordedAt);

  /// 这条记录所属的「天」的键（分组/聚合用）。
  String get recordedDayKey => dayKey(recordedAt);

  /// 是不是补记的：入库那天 ≠ 记录归属那天。
  ///
  /// 例：8 月 1 日忘了记，8 月 5 日补交 → recordedAt 落在 8/1，createdAt 落在 8/5
  /// → 判定为补记。
  bool get isBackfilled => !isSameDay(recordedAt, createdAt);

  /// 补记发生在记录日之后几天（非补记返回 0）。
  int get backfillDelayDays =>
      isBackfilled ? dayDiff(recordedAt, createdAt) : 0;

  /// 归属日是否为今天。
  bool isRecordedToday([DateTime? now]) =>
      isSameDay(recordedAt, now ?? DateTime.now());

  /// 是否在指定日期区间内（含首尾天）。
  bool isInDayRange(DateTime from, DateTime to) =>
      !recordedAt.isBefore(dayStart(from)) && recordedAt.isBefore(nextDayStart(to));
}
