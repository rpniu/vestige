import 'package:flutter/material.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/widgets/row_metrics.dart';

/// 单条记录的卡片。
///
/// **高度由外部给定，不由内容撑出来** —— 这是首页能用 `SliverVariedExtentList` 做
/// 算术定位跳转的前提（见 [VestigeRowMetrics] 的说明）。所以卡片内部：
///
/// - 用 `Column(mainAxisAlignment: center)` 把内容竖直居中，高度富余时是「留白」而不是「拉伸」；
/// - 正文行数按「有标题 1 行 / 没标题 2 行」两档封顶，**没有标题就不再占一行空白**
///   （旧版这里是一个 `Spacer()`，没有标题也白吃一行高度）；
/// - 标签和「补记」从原来的多行 `Wrap` + 单独一行，压成**一行元信息**，超出打省略号。
///
/// 与旧版的另一处差别：所有时间展示都基于 **recordedAt（业务日期）**，
/// 并在补记的条目上打标记 —— 一眼就能看出「这条是当天顺手记的」还是「事后补交的」。
class RecordCard extends StatelessWidget {
  const RecordCard({
    super.key,
    required this.record,
    this.selected = false,
    this.selectionMode = false,
    this.showDay = false,
    this.onTap,
    this.onLongPress,
  });

  final RecordEntity record;

  /// 多选模式下的选中态。
  final bool selected;

  /// 是否处于多选模式（决定点击行为与头像样式）。
  final bool selectionMode;

  /// 是否在卡片里显示日期（回收站里跨天混杂时有用）。
  final bool showDay;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// **仅测试用**：累计 [RecordCard] 的 build 次数。
  ///
  /// 首页「跳到底时只构建可见行、而不是把中间几千行全走一遍」的回归测试靠它抓退化
  /// （`test/widget/home_fixed_row_test.dart`）。包在 `assert` 里，
  /// release 构建下整段被裁掉，零开销。
  static int debugBuildCount = 0;

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugBuildCount++;
      return true;
    }());

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    final title = record.cardTitle;
    final hasTitle = title != null;
    final meta = _buildMeta(context);

    // 卡片走实色容器面，和页面底拉开一档明度差 —— 以前是
    // `surfaceContainerHighest @ 45%` 叠出来的近底色，卡片只能靠 1px 描边站立。
    final background = selected ? scheme.primaryContainer : surfaces.card;

    return Card(
      elevation: selected ? 2 : 0.8,
      shadowColor: scheme.shadow.withValues(alpha: selected ? 0.14 : 0.05),
      color: background,
      // 显式写零边距：行高由外部声明，卡片必须**正好**填满这个高度。
      // 主题里虽然也配了 `cardTheme.margin = zero`，但这里不依赖它 ——
      // 哪天主题改回去，卡片高度和声明行高就会错开，变成 1px 缝或溢出。
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: selected
            ? BorderSide(color: scheme.primary, width: 1.6)
            : BorderSide(color: surfaces.border, width: 0.8),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: VestigeRadius.mediumAll,
        child: Padding(
          // 左右比上下多 4：内容不贴边，卡片在视觉上更「稳」；
          // 上下必须凑够 VestigeRowMetrics.cardPadding（行高的组成部分），左右自由。
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            // 卡片高度是给定的：内容整体竖直居中，高度有富余时上下对称留白。
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _TimeBadge(
                record: record,
                showDay: showDay,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (hasTitle) ...<Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      record.content,
                      // 两档封顶，保证「标题 + 正文」的总行数不超过 VestigeRowMetrics.cardTextSlot
                      // 那条预算（有标题时正文 1 行，没标题时正文 2 行）。
                      maxLines: hasTitle ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                        height: 1.35,
                      ),
                    ),
                    if (meta != null) ...<Widget>[
                      const SizedBox(height: 3),
                      meta,
                    ],
                  ],
                ),
              ),
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一行元信息：补记标记 + 标签。都没有时返回 null（整行不占高度）。
  ///
  /// 压成一行是行高可预知的必要条件 —— 旧版的 `Wrap` 标签会随标签数量涨到两三行。
  Widget? _buildMeta(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final tags = record.tags;

    if (!record.hasCardMeta) return null;
    final backfilled = record.isBackfilled;

    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (backfilled) ...<InlineSpan>[
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                Icons.history_toggle_off,
                size: 12,
                color: tokens.backfill,
              ),
            ),
            TextSpan(
              text: ' ${friendlyDayLabel(record.createdAt)}补记',
              style: TextStyle(
                color: tokens.backfill,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (record.backfillDelayDays > 0)
              TextSpan(
                text: ' · 隔 ${record.backfillDelayDays} 天',
                style: TextStyle(color: tokens.backfill),
              ),
          ],
          if (backfilled && tags.isNotEmpty) const TextSpan(text: '   '),
          if (tags.isNotEmpty)
            TextSpan(
              text: tags.map((String t) => '#$t').join('  '),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall,
    );
  }
}

/// 左侧时间徽标：时分 + （可选）日期。
///
/// **高度被主动锁死在「1 行 / 2 行」**，永远是 [VestigeRowMetrics] 行高预算里那块砖的尺寸：
/// 时间是靠 [FittedBox] 等比缩小塞进 54px 的，**绝不换行**。
///
/// 这条约束并非苛求：徽标一旦折成两行（系统字号放大、或测试里的假字体每个字形都是 1em 宽），
/// 高度就从 32 涨到 48，直接把紧凑档（内高 40）顶破 —— 黄黑条纹 + 内容被裁。
/// `test/widget/home_fixed_row_test.dart` 在 1.0~1.6 各档字号下钉住了这一点。
///
/// 注意 [showDay] 打开时徽标是两行（50 高），比紧凑档的内高还大 ——
/// 所以它只给**不声明行高**的列表用（回收站），首页不要传。
class _TimeBadge extends StatelessWidget {
  const _TimeBadge({
    required this.record,
    required this.showDay,
  });

  final RecordEntity record;
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = VestigeTokens.of(context);
    final isBackfilled = record.isBackfilled;

    final onBadge = isBackfilled
        ? tokens.onBackfillContainer
        : scheme.onPrimaryContainer;

    // 徽标走**实色**（不再是 55% 半透明）—— 它是卡片上唯一带色彩的元素，
    // 半透明时会被卡片底色冲淡成一团灰蓝；实色之后「补记=琥珀、当天记=主蓝」
    // 这套语义才真正读得出来。圆角取 [VestigeRadius.inset]（12），
    // 与卡片 24 圆角形成「外大内小」的同心情侣关系。
    final borderColor = isBackfilled
        ? tokens.backfill.withValues(alpha: 0.22)
        : scheme.primary.withValues(alpha: 0.16);

    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: isBackfilled ? tokens.backfillContainer : scheme.primaryContainer,
        borderRadius: VestigeRadius.insetAll,
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _oneLine(
            timeLabel(record.recordedAt),
            Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: onBadge,
                ),
          ),
          if (showDay) ...<Widget>[
            const SizedBox(height: 2),
            _oneLine(
              '${record.recordedAt.month}/${record.recordedAt.day}',
              Theme.of(context).textTheme.labelSmall?.copyWith(color: onBadge),
            ),
          ],
        ],
      ),
    );
  }

  /// 单行文本：放不下就等比缩小，不换行。这样高度恒等于一行，不会随字号/字体变。
  Widget _oneLine(String text, TextStyle? style) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      );
}

/// 「这张卡片长什么形状」的判定 —— 卡片渲染与首页行高**共用这一份**。
///
/// 为什么必须共用：首页的行高是按形状分档声明的（紧凑档 / 完整档，见
/// [VestigeRowMetrics.denseTextSlot]），而卡片内部渲染也按同一形状决定要不要出
/// 标题行、元信息行。两边一旦判断不一致（比如一边认为没标题、一边认为有），
/// 结果就是内容被裁 —— 所以判定规则只能有一处。
extension RecordCardShapeX on RecordEntity {
  /// 标题（去掉首尾空白）；纯空白或缺失都算没有标题，返回 null。
  String? get cardTitle {
    final t = title?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// 有标题。
  bool get hasCardTitle => cardTitle != null;

  /// 有元信息行：补记标记或标签。
  bool get hasCardMeta => isBackfilled || tags.isNotEmpty;

  /// 只有正文、没有标题也没有元信息 → 行高可以走紧凑档。
  bool get isDenseCard => !hasCardTitle && !hasCardMeta;
}
