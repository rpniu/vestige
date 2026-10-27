import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/app/motion.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/duration_format.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/widgets/center_dialog.dart';
import 'package:vestige/presentation/widgets/error_state.dart';
import 'package:vestige/presentation/widgets/monthly_bar_chart.dart';
import 'package:vestige/presentation/widgets/record_calendar.dart';

/// 统计页：年度月度分布（柱状）+ 记录日历 + 标签分布 + 记录习惯的洞察数字。
///
/// 2026-09-16 按用户要求去掉了原来的「近期走势」日粒度折线图
/// （7/30/90 天窗口 + 实线总条数 / 琥珀虚线补记）。
/// 原因：秒记场景下日条数分布是「大量 0 + 偶尔尖峰」，折线会被单个爆发日拉高
/// 而其余天贴着 0，看不出趋势；它想表达的「记不记得住、补记多不多」
/// 下面这张洞察卡的数字已经覆盖，数字比曲线好读。
///
/// 注意：[dailySeriesProvider] / [buildDailySeries] / [DayStat] 仍然活着 ——
/// 洞察卡的四个数字与性能基准（`test/perf/hot_path_bench_test.dart`）都在用，
/// 不应随之删除。日粒度的**图表**组件已经随这次删除去掉了。
///
/// 2026-09-23：7/30/90 那套窗口选择器**回来了**，挂在洞察卡标题右边。
///
/// 2026-09-28：洞察卡改为**窗口口径** —— 四个数字（近 N 天条数 / 其中补记 /
/// 有记录天数 / 日均条数）全部是当前选中窗口内的，与标题右侧的选择器口径一致；
/// 原先那四个全时段数字（总记录数 / 连续记录 / 活跃天数 / 补记占比）与
/// 「我的」页头卡重复，已移除。底部那句「近 N 天共 X 条…」小字一并删除
/// （数字已在格子里），只留全时段的补记说明框。
///
/// 全部按**业务日期 recordedAt** 统计，因此补记的条目会落在它归属的那一天，
/// 而不是把它「补进今天」——统计口径和记忆口径保持一致。
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 错误态优先于一切：数据读不出来时，下面每一张卡都会算成 0/空 ——
    // 那与「统计确实是空的」无法区分，属于误导（2026-10-27 审查 C-001）。
    final recordsAsync = ref.watch(recordsProvider);
    if (recordsAsync.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('统计')),
        body: VestigeErrorState(
          error: recordsAsync.error!,
          onRetry: () => ref.invalidate(recordsProvider),
        ),
      );
    }

    final stats = ref.watch(recordStatsProvider);
    final monthly = ref.watch(monthlyStatsProvider);
    // 窗口长度由洞察卡标题右边那颗选择器控制（见 insightWindowProvider）。
    // 卡里四个数字都是这个窗口口径的，所以选择器一换、四个数字一起跟着变。
    final window = ref.watch(insightWindowProvider);
    final series = ref.watch(dailySeriesProvider(window));
    final years = ref.watch(availableYearsProvider);
    final shownYear = ref.watch(shownYearProvider);
    final yearTotals = ref.watch(yearTotalsProvider);
    final tagStats = ref.watch(tagStatsProvider);
    // 柱图那 12 个月加起来就是这一年的总条数，跟着图走最稳（不会出现图注和图不一致）。
    final yearTotal = monthly.fold<int>(0, (p, e) => p + e.count);
    final hasData = stats.totalCount > 0;

    return Scaffold(
      appBar: AppBar(title: const Text('统计')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _SectionCard(
            title: '月度分布',
            // 年份已经由右上角那颗选择按钮显眼地显示了，副标题不再重复它
            subtitle: '每月条数 · 琥珀色段为其中补记',
            trailing: _YearPicker(
              years: years,
              selected: shownYear,
              // 弹层里每行末尾的「N 条」：不打开只能看到当前这一年的合计，
              // 打开就能一眼比出哪年记得多（用户在意的正是「每年的总量」）。
              totals: yearTotals,
              onSelected: (value) =>
                  ref.read(selectedYearProvider.notifier).select(value),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MonthlyBarChart(data: monthly, height: 240),
                // 合计放在图**下面**当图注，而不是挤进标题那行：
                // 标题行要与年份药丸分宽度，窄屏上「该年共 128 条 · 琥珀色段为其中补记」
                // 这种长度必然折行；图注独占一行就完全没有这个约束。
                _YearTotalCaption(total: yearTotal),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 月度分布是「年」的视角，记录日历是「月」的下钻：哪天记了、
          // 哪天断了、哪天是补的，一张网格读完。
          const _SectionCard(
            title: '记录日历',
            subtitle: '格子越深条数越多 · 点格子看当天记录',
            child: RecordCalendar(),
          ),
          const SizedBox(height: 16),
          // 前两张卡都是**时间**维度（年 → 月），这张换个维度：标签。
          // 标签在这个 App 里是一等公民（筛选、批量打标签都围着它转），
          // 却一直没有统计视角 —— 这里补上「哪些标签用得最多」。
          _SectionCard(
            title: '标签分布',
            subtitle: '该年各标签被用到的次数 · 一条记录可带多个标签',
            child: _TagBars(tags: tagStats),
          ),
          const SizedBox(height: 16),
          _InsightCard(
            stats: stats,
            series: series,
            hasData: hasData,
            window: window,
            onWindowChanged: (int days) =>
                ref.read(insightWindowProvider.notifier).select(days),
          ),
          // 时长卡只在窗口内真的有时长数据时出现 —— 从不填时长的用户
          // 不该在统计页多看到一张全是 0 的卡。
          if (_windowDurationStats(series) case (
            final total,
            final max,
          )) ...<Widget>[
            const SizedBox(height: 16),
            _DurationCard(
              windowDays: series.length,
              totalSeconds: total,
              maxSeconds: max,
            ),
          ],
        ],
      ),
    );
  }

  /// 窗口内的时长汇总：`(总秒, 最长单条秒)`。
  ///
  /// 窗口内一条带时长的记录都没有时返回 null（整张卡不渲染）。
  /// 时长跟条数同一口径 —— 按业务日期落在它归属的那一天。
  ///
  /// 不提供「日均时长」（2026-10-22 用户要求删除）：只填时长的那部分记录
  /// 除以整个窗口天数，得到的数往往小到没有信息量（例如几分钟摊到 30 天
  /// 只剩个位数秒），容易被误读成「数据错了」。
  static (int, int)? _windowDurationStats(List<DayStat> series) {
    var total = 0;
    var max = 0;
    for (final day in series) {
      for (final r in day.records) {
        final d = r.durationS;
        if (d == null) continue;
        total += d;
        if (d > max) max = d;
      }
    }
    if (total == 0) return null;
    return (total, max);
  }
}

/// 「月度分布」图下面那行图注：**该年共多少条**（数字加重）。
///
/// 柱顶上虽然有数字，但要看「这一年到底记了多少」得把 12 根柱子一根根读过去，
/// 还容易漏掉自己滑过去的月份 —— 合计一次给到，不用算。
class _YearTotalCaption extends StatelessWidget {
  const _YearTotalCaption({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 细分隔线：图里没画坐标轴框线（只有横向虚线网格），
        // 没这条线的话图注会像是 X 轴标签的一部分。
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          // 这一年一条都没有：柱子全是灰墩子，「该年共 0 条」不如直说
          child: total == 0
              ? Text('该年还没有记录', style: base)
              : Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      const TextSpan(text: '该年共 '),
                      TextSpan(
                        text: '$total',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const TextSpan(text: ' 条'),
                    ],
                    style: base,
                  ),
                ),
        ),
      ],
    );
  }
}

/// 标签分布：每行一个标签，用一根横向比例条表示用量。
///
/// 条宽按「占**最多那个标签**的比例」给，**不是**占全部的比例 ——
/// 一条记录可以带多个标签，各项占比相加会超过 100%，那样的条没法读。
/// 所以这张图表达的是**相对排序**，绝对次数写在右边。
class _TagBars extends StatelessWidget {
  const _TagBars({required this.tags});

  /// 已按次数降序（见 `tagStatsProvider`）。
  final List<({String tag, int count})> tags;

  /// 最多列几行。再多卡片会长得离谱，而这是个「一眼看最常用的几个」的视图，
  /// 不是要逐条核对的清单。
  static const int maxRows = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (tags.isEmpty) {
      return Text(
        '这一年还没有带标签的记录。\n在编辑页给记录加上标签，这里就能看出哪些用得最多。',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.6,
        ),
      );
    }

    final top = tags.take(maxRows).toList(growable: false);
    // 已降序 → 第一行就是最多的那个，拿它当满格基准
    final maxCount = top.first.count;
    final rest = tags.length - top.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final t in top)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _TagBar(
              tag: t.tag,
              count: t.count,
              ratio: t.count / maxCount,
            ),
          ),
        if (rest > 0)
          Text(
            '还有 $rest 个标签未列出',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// 一行：标签名（定宽）+ 比例条 + 次数。
class _TagBar extends StatelessWidget {
  const _TagBar({required this.tag, required this.count, required this.ratio});

  final String tag;
  final int count;

  /// 0~1，相对最多的那个标签。
  final double ratio;

  /// 条高定死：各行同一个值，横向才比得了。
  static const double _barHeight = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: <Widget>[
        // 标签名定宽：不定宽的话每行的条起点都不一样，横向就没法比了。
        // 超长标签省略号收尾（完整名字在首页筛选弹层里能看全）。
        SizedBox(
          width: 76,
          child: Text(
            '#$tag',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) => Stack(
              children: <Widget>[
                // 底槽画满整行，条才有「占了多长」的参照
                _bar(scheme.surfaceContainerHighest, c.maxWidth),
                _bar(scheme.primary, c.maxWidth * ratio),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 36,
          child: Text(
            '$count',
            textAlign: TextAlign.right,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  /// 一根定高的圆头条。
  ///
  /// 手写 `Container` 而不是用 `LinearProgressIndicator`：M3 的进度条自带
  /// stop 指示点 + 圆角收尾那套新样式，画出来读作「进度」；
  /// 这里要表达的是「占比」，多出来的装饰反而干扰。
  Widget _bar(Color color, double width) => Container(
    width: width,
    height: _barHeight,
    decoration: BoxDecoration(
      color: color,
      borderRadius: VestigeRadius.pillAll,
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Card(
      elevation: 0.8,
      shadowColor: scheme.shadow.withValues(alpha: 0.05),
      color: surfaces.card,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(color: surfaces.border, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 3.5,
                  height: 14,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// 年份选择：一颗「药丸」按钮（日历图标 + 年份 + 展开箭头），点开是**模态底部弹层**。
///
/// 原来是一个裸 `DropdownButton`，只有两个问题：
/// 1. 外观：没有底色/描边/箭头（连 `underline` 都去掉了），摆在卡片右上角像一段**说明文字**，
///    看不出能点；点出来的浮层菜单也只能调底色和圆角，很素。
/// 2. 交互：它的浮层确实会挡住统计页的滚动，但那是 Flutter 弹层自带 `ModalBarrier` 的
///    **隐式**副作用，看不出来是有意设计的。
///
/// 现在按钮给药丸外观（卡内凹槽底 + 极淡描边 + 16 圆角 +
/// 主色图标），点开换成 [showModalBottomSheet]：视觉上是全站一致的 32 圆角弹层
/// （抓手条 + 标题 + 带勾选的年份列表），语义上**明确是模态** ——
/// 弹层开着时统计页滑不动（遮罩挡住拖拽和滚轮），选完/取消后立刻恢复。
/// 这条行为由 `test/widget/year_picker_test.dart` 钉住。
///
/// [totals] 是「每一年多少条」，弹层每行末尾会显示它 —— 年份列表本来就是
/// 唯一能横着比较各年份的地方，把总量放在这里比放在任何单年视图里都有用。
class _YearPicker extends StatelessWidget {
  const _YearPicker({
    required this.years,
    required this.selected,
    required this.totals,
    required this.onSelected,
  });

  final List<int> years;
  final int selected;
  final Map<int, int> totals;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Material(
      color: surfaces.inset,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.smallAll,
        side: BorderSide(color: surfaces.border),
      ),
      child: InkWell(
        onTap: () => _pick(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.event_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                '$selected 年',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showVestigeCenterDialog<int>(
      context: context,
      // 屏高八成：记了七八年之后六成要滚很久（标签筛选/操作历史同此尺寸）。
      builder: (BuildContext context) =>
          _YearSheet(years: years, selected: selected, totals: totals),
      maxHeightFactor: 0.8,
    );
    if (picked != null) onSelected(picked);
  }
}

/// 年份弹层的内容：标题 + 年份列表（当前年份带勾选、底色高亮，每行右侧标出该年总条数）。
class _YearSheet extends StatelessWidget {
  const _YearSheet({
    required this.years,
    required this.selected,
    required this.totals,
  });

  final List<int> years;
  final int selected;
  final Map<int, int> totals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ConstrainedBox(
      // 最多占八成屏高，超出就让列表滚 —— 2 个年份时它就是一个紧凑的小弹层
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: <Widget>[
                Text(
                  '选择年份',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                // 这里原来写「共 N 个」。每行的「N 条」才是重点，
                // 标题右侧不放全年合计 —— 合计已在月度分布卡的图注里给过了，无需重复。
                Text(
                  '共 ${years.length} 年',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              children: <Widget>[
                for (final year in years) _tile(context, year),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, int year) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = year == selected;
    final count = totals[year] ?? 0;

    return ListTile(
      // 不用 dense：与标签筛选弹层同一档 —— 标准 56 高行 + 大一号的年份文字，
      // 弹层才不显得狭窄（2026-10-22 用户反馈）。
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      visualDensity: const VisualDensity(horizontal: 0, vertical: 2),
      selected: isSelected,
      // 实色高亮：弹层底色是容器白，0.5 半透明的浅蓝叠上去几乎看不出选中。
      selectedTileColor: scheme.primaryContainer,
      title: Text(
        '$year 年',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          color: isSelected ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '$count 条',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isSelected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          // 勾选图标的位置**每行都占着**（没选中就留空），这样「N 条」是一列对齐的。
          // 只在选中行插入图标的话，那一行的数字会被往左挤 28px（8 + 20），
          // 年份列表最该方便比较的就是这一列数字，结果它自己先错位了。
          SizedBox(
            width: 20,
            height: 20,
            child: isSelected
                ? Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: scheme.primary,
                  )
                : null,
          ),
        ],
      ),
      onTap: () => Navigator.of(context).pop(year),
    );
  }
}

/// 「记录习惯」卡：**窗口口径**（近 N 天）的四个数字。
///
/// 排版要点（2026-09-16 重排，2026-09-28 改为窗口口径）：
/// - 数字格子**等宽铺满**整行，不再用「固定 104 宽 + `Wrap`」—— 原来在手机上只能排成
///   2+2+1：最后一行孤零零一个格子，而且右边永远空一截（5 × 104 本来也塞不进一行）。
/// - 只留 **4 个数字**：近 N 天条数 / 其中补记 / 有记录天数 / 日均条数。
///   4 对窄屏 2 列、宽屏 4 列都整除，永远不会出现半行。
///
/// **为什么不再展示「总记录数 / 连续记录 / 活跃天数 / 补记占比」**（2026-09-28 用户要求）：
/// 那四个是全时段口径，而「我的」页头卡已经展示了「共 N 条记录 · 活跃 X 天 · 连续 Y 天 ·
/// 补记 Z 条」，两处重复。这张卡改为只回答「**最近 N 天记得怎么样**」——
/// 它上面的窗口选择器控制什么，下面四个数字就都是那个窗口的，
/// 标题、选择器、数字三者口径统一。
///
/// 全时段的两条信息（补记总数、最长补记间隔）仍保留在底部那条琥珀说明框里 ——
/// 它讲的不是「总量重复」，而是「补记也算数」这个口径说明。
class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.stats,
    required this.series,
    required this.hasData,
    required this.window,
    required this.onWindowChanged,
  });

  final RecordStats stats;
  final List<DayStat> series;
  final bool hasData;

  /// 当前窗口长度（天），以及换窗口的回调。
  ///
  /// 由外面传进来而不是卡片自己 watch：卡片是纯展示组件，
  /// 让它碰 provider 就没法单独喂数据测了。
  final int window;
  final ValueChanged<int> onWindowChanged;

  /// 卡片内宽超过这个值就用 4 列，否则 2 列。
  static const double _wideBreakpoint = 520;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);

    final windowDays = series.length;
    final windowTotal = series.fold<int>(0, (p, e) => p + e.count);
    final windowBackfill = series.fold<int>(0, (p, e) => p + e.backfilled);
    final activeInWindow = series.where((e) => e.count > 0).length;
    // 日均条数：窗口总条数 ÷ 窗口天数，保留一位小数。
    // 用 series.length（而不是传进来的 window）做分母：series 的长度就是窗口长度，
    // 两者若哪天不一致（比如窗口被夹到可用范围），分母也该跟着实际画出来的天数走。
    final perDay = windowDays == 0 ? 0.0 : windowTotal / windowDays;

    return Card(
      elevation: 0.8,
      shadowColor: scheme.shadow.withValues(alpha: 0.05),
      color: surfaces.card,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(color: surfaces.border, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 标题 + 窗口选择器用 Wrap（spaceBetween）而不是 Row + Spacer：
            // 大字号下三个 chip 可能挤不下，Wrap 会自己折成两行，
            // Row 则会直接黄黑条纹溢出。
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                Text(
                  '记录习惯',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                // 窗口选择器：7 / 30 / 90 天。放在标题右边而不是另起一行 ——
                // 它控制的就是下面四个数字的口径，挨着读最顺。
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final days in kInsightWindowOptions)
                      ChoiceChip(
                        label: Text('$days 天'),
                        selected: window == days,
                        onSelected: (_) => onWindowChanged(days),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelStyle: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) =>
                  _metricGrid(
                    columns: constraints.maxWidth >= _wideBreakpoint ? 4 : 2,
                    tiles: <Widget>[
                      _Metric(
                        label: '近 $windowDays 天',
                        value: '$windowTotal',
                        unit: '条',
                      ),
                      _Metric(
                        label: '其中补记',
                        value: '$windowBackfill',
                        unit: '条',
                        highlight: windowBackfill > 0,
                      ),
                      _Metric(
                        label: '有记录天数',
                        value: '$activeInWindow',
                        unit: '天',
                      ),
                      _Metric(
                        label: '日均条数',
                        value: perDay.toStringAsFixed(1),
                        unit: '条',
                      ),
                    ],
                  ),
            ),
            const SizedBox(height: 14),
            // 全时段的补记事实 + 口径说明。与「我的」页头卡的「补记 N 条」不同：
            // 那句是计数，这里是「补记算什么」的说明，并把最长间隔一并交代。
            if (stats.backfilledCount > 0) ...<Widget>[
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: tokens.backfillContainer,
                  borderRadius: VestigeRadius.smallAll,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.history_toggle_off,
                        size: 15,
                        color: tokens.onBackfillContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '有 ${stats.backfilledCount} 条是事后补记的——'
                        '补记不算漏记，统计里会算进它真正归属的那一天'
                        // 最长间隔原来是网格里的第 5 个格子，现在并到这句里
                        '${stats.maxBackfillDelay > 0 ? '，最长一次隔了 ${stats.maxBackfillDelay} 天才补上' : ''}。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: tokens.onBackfillContainer,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (!hasData) ...<Widget>[
              // 一条记录都没有：给一句引导，而不是让四个 0 干摆着。
              Text(
                '还没有数据，先记一条试试。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 等宽网格：每行 [columns] 个格子，最后一行不够就用空位补齐，
  /// 这样最后一行的格子宽度与前几行一致，不会有一个格子被拉成整行宽。
  Widget _metricGrid({required int columns, required List<Widget> tiles}) {
    final rows = <Widget>[];
    for (var start = 0; start < tiles.length; start += columns) {
      final end = start + columns > tiles.length
          ? tiles.length
          : start + columns;
      final inRow = tiles.sublist(start, end);
      rows.add(
        Row(
          spacing: 10,
          children: <Widget>[
            for (final tile in inRow) Expanded(child: tile),
            for (var i = inRow.length; i < columns; i++)
              const Expanded(child: SizedBox.shrink()),
          ],
        ),
      );
    }
    return Column(spacing: 10, children: rows);
  }
}

/// 「记录时长」卡：窗口口径的时长汇总，挂在「记录习惯」卡下面。
///
/// 只回答两个数：**这个窗口里一共花了多久**（主数值）和**最长的一条多久**
/// （次级）。2026-10-22 按用户要求删掉了「日均时长」—— 只填时长的那部分
/// 记录除以整个窗口天数，经常小到只剩几秒，看着像数据出错。
///
/// 不带自己的窗口选择器 —— 它的口径与「记录习惯」卡右上角那个选择器**同源**
/// （同一个 [insightWindowProvider]），重复摆一组 chip 只会让人怀疑两处口径
/// 不一致。窗口内没有任何带时长的记录时整张卡不出现（见
/// [StatsScreen._windowDurationStats]），从不用时长的用户多不出一张空卡。
class _DurationCard extends StatelessWidget {
  const _DurationCard({
    required this.windowDays,
    required this.totalSeconds,
    required this.maxSeconds,
  });

  final int windowDays;
  final int totalSeconds;
  final int maxSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Card(
      elevation: 0.8,
      shadowColor: scheme.shadow.withValues(alpha: 0.05),
      color: surfaces.card,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(color: surfaces.border, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 标题行：图标徽标 + 两行文字（与「我的」页设置行同一套 38px 语言）
            Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: VestigeRadius.insetAll,
                  ),
                  child: Icon(
                    Icons.timelapse_rounded,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '记录时长 · 近 $windowDays 天',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '只统计填了时长的记录',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 主数值独占一行（总时长是这张卡的问题「最近花了多少时间」的答案），
            // 最长一条退到下面一行小字。
            Text(
              durationLabel(totalSeconds),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            _MiniStat(label: '最长一条', value: durationLabelCompact(maxSeconds)),
          ],
        ),
      ),
    );
  }
}

/// 时长卡下方的次级指标：小标签 + 等宽数值。
class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// 单个数字格子：标签 + 「数字 + 单位」。宽度由外层 [Expanded] 决定（等宽铺满）。
class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String unit;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        // 普通格子走卡内凹槽面 + 描边：白卡上单靠 3% 的明度差太弱，
        // 一条极淡的描边才让「这是四个格」读得出来。补记格直接用实色琥珀。
        color: highlight ? tokens.backfillContainer : surfaces.inset,
        borderRadius: VestigeRadius.smallAll,
        // 高亮格用**透明**描边而不是不放描边：border 会计入容器尺寸，
        // 少一圈 1px 就会让高亮格比同排的普通格矮 2px，Row 居中之后两块错开 1px
        // （insight_card_test 断言「四块等高、同行齐平」，这个 1px 会被抓住）。
        border: Border.all(
          color: highlight
              ? tokens.backfill.withValues(alpha: 0.28)
              : surfaces.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            // 单行 + 省略号：格子等宽靠的就是「每个格子结构一样高」，
            // 标签一旦折行，同一行的两块就会一高一矮（跨行不齐比截断更难看）。
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: highlight
                  ? tokens.onBackfillContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Flexible(
                // 数字滚动：首次进入从 0 计数到目标值，窗口切换（7/30/90）时
                // 从当前值平滑过渡到新值（TweenAnimationBuilder 的 end 变化
                // 会从当前插值继续）。数字用 tabular figures，滚动中不抖宽。
                // 解析失败（非数字值）时退回普通 Text，组件不承担格式约定。
                child: _CountUpText(
                  value: value,
                  maxLines: 1,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: highlight ? tokens.backfill : scheme.primary,
                    // 等宽数字：四个格子的数字跳动时不会让格子宽度跟着抖
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Text(
                unit,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: highlight
                      ? tokens.onBackfillContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「会数数的文本」：数字值从 0（或上一值）平滑滚到目标值。
///
/// 只用于 [ _Metric ] 的数字格。值必须是纯数字（整数或一位小数）；
/// 解析失败时退回普通 Text。样式、溢出行为与普通 Text 一致。
class _CountUpText extends StatelessWidget {
  const _CountUpText({required this.value, required this.style, this.maxLines});

  final String value;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final target = double.tryParse(value);
    if (target == null) {
      return Text(
        value,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final isDecimal = value.contains('.');
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: VestigeMotion.slow,
      curve: VestigeMotion.curve,
      builder: (context, t, _) => Text(
        isDecimal ? t.toStringAsFixed(1) : '${t.round()}',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
