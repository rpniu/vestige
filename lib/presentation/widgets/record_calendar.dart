import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/calendar_util.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/widgets/center_dialog.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

/// 「记录日历」月历热力图：一个月一张 7 列网格，格子越深色条数越多，
/// 含补记的日子右上角带一颗琥珀点；点有记录的日子弹出当天的记录列表。
///
/// 着色用「primaryContainer → primary」的同族渐变：0 条的凹槽色、
/// 满条的实主色都是主题里已有的角色，不引入新的色板。
/// 深度的参照是**当月最大条数**（相对深度，而不是固定阈值）——
/// 这样「一天 30 条」的月份和「一天 2 条」的月份都能用满整段色阶。
class RecordCalendar extends ConsumerWidget {
  const RecordCalendar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = ref.watch(calendarMonthProvider);
    final stats = ref.watch(calendarStatsProvider);
    final cells = buildMonthGrid(shown.year, shown.month, stats);
    final maxCount = stats.values.fold<int>(
      0,
      (p, e) => e.count > p ? e.count : p,
    );
    // 展示的是当月时不能「再往后翻」——未来还没有发生
    final now = DateTime.now();
    final canGoNext =
        shown.year < now.year ||
        (shown.year == now.year && shown.month < now.month);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 月份导航：‹ 2026年9月 ›
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _NavButton(
              icon: Icons.chevron_left_rounded,
              tooltip: '上个月',
              onTap: () => ref.read(calendarMonthProvider.notifier).shift(-1),
            ),
            SizedBox(
              width: 132,
              child: Text(
                '${shown.year}年${shown.month}月',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _NavButton(
              icon: Icons.chevron_right_rounded,
              tooltip: '下个月',
              onTap: canGoNext
                  ? () => ref.read(calendarMonthProvider.notifier).shift(1)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 星期表头（周一起）
        Row(
          children: <Widget>[
            for (final label in const <String>[
              '一',
              '二',
              '三',
              '四',
              '五',
              '六',
              '日',
            ])
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        // 网格限宽居中：格子是正方形的，桌面宽屏下不约束就会变成
        // 一面墙的巨型方块 —— 月历是「一屏读完」的信息密度，不是铺满。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              children: <Widget>[
                for (final cell in cells)
                  switch (cell) {
                    CalendarBlankCell() => const SizedBox.shrink(),
                    CalendarDayCell() => _DayCell(
                      cell: cell,
                      maxCount: maxCount,
                      // 选中某天的确认触觉（桌面端自动无效）。
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _showDaySheet(context, ref, shown, cell);
                      },
                    ),
                  },
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        const _Legend(),
      ],
    );
  }

  void _showDaySheet(
    BuildContext context,
    WidgetRef ref,
    ({int year, int month}) shown,
    CalendarDayCell cell,
  ) {
    if (cell.stat.count == 0 || cell.isFuture) return;
    final day = DateTime(shown.year, shown.month, cell.day);
    final records =
        (ref.read(recordsProvider).valueOrNull ?? const <RecordEntity>[])
            .where((r) => isSameDay(r.recordedAt, day))
            .toList();
    showVestigeCenterDialog<void>(
      context: context,
      builder: (context) => _DayRecordsSheet(day: day, records: records),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onTap,
      color: onTap == null ? scheme.outlineVariant : scheme.primary,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// 一个日格：方形，底色随条数加深，补记带琥珀点，今天带主色描边。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.cell,
    required this.maxCount,
    required this.onTap,
  });

  final CalendarDayCell cell;

  /// 当月最大条数（相对深度的参照），0 表示当月一条都没有。
  final int maxCount;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);

    final count = cell.stat.count;
    final t = maxCount == 0 ? 0.0 : count / maxCount;

    final Color bg;
    final Color fg;
    if (cell.isFuture || count == 0) {
      bg = surfaces.inset;
      fg = cell.isFuture ? scheme.outlineVariant : scheme.onSurfaceVariant;
    } else {
      // 0.25 起步：1 条和 0 条要一眼分得开，不能像「浅一点的空格子」
      bg = Color.lerp(
        scheme.primaryContainer,
        scheme.primary,
        0.25 + 0.75 * t,
      )!;
      fg = t > 0.5 ? scheme.onPrimary : scheme.onPrimaryContainer;
    }

    return Material(
      color: bg,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.insetAll,
        // 描边画在格子**内部**，不影响格子尺寸 —— 等宽格子的装饰差异
        // 不能落在尺寸上（否则同行格子错位）。
        side: cell.isToday
            ? BorderSide(color: scheme.primary, width: 1.8)
            : BorderSide(
                color: surfaces.border.withValues(alpha: 0.45),
                width: 0.6,
              ),
      ),
      child: InkWell(
        onTap: count > 0 && !cell.isFuture ? onTap : null,
        child: Stack(
          children: <Widget>[
            Center(
              child: Text(
                '${cell.day}',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: count > 0 ? FontWeight.w800 : FontWeight.w500,
                  color: fg,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
            if (cell.stat.hasBackfill && !cell.isFuture)
              Positioned(
                top: 3,
                right: 3,
                child: Container(
                  key: const ValueKey<String>('calendar-backfill-dot'),
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: tokens.backfill,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 图例：色阶（少 → 多）+ 琥珀点含义。
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Row(
      children: <Widget>[
        Text('少', style: labelStyle),
        const SizedBox(width: 4),
        _swatch(surfaces.inset),
        _swatch(Color.lerp(scheme.primaryContainer, scheme.primary, 0.25)!),
        _swatch(Color.lerp(scheme.primaryContainer, scheme.primary, 0.6)!),
        _swatch(scheme.primary),
        const SizedBox(width: 4),
        Text('多', style: labelStyle),
        const Spacer(),
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: tokens.backfill,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text('含补记', style: labelStyle),
      ],
    );
  }

  Widget _swatch(Color color) => Container(
    width: 12,
    height: 12,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// 点某个日格弹出的当天记录列表。
class _DayRecordsSheet extends StatelessWidget {
  const _DayRecordsSheet({required this.day, required this.records});

  final DateTime day;
  final List<RecordEntity> records;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            child: Row(
              children: <Widget>[
                Text(
                  groupHeaderLabel(day),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${records.length} 条',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              itemCount: records.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: RecordCard(
                  record: records[index],
                  onTap: () {
                    Navigator.of(context).pop();
                    context.push(AppRoutes.editExisting(records[index].id));
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
