import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/record_dao.dart' show kSearchResultLimit;
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/search_history_provider.dart';
import 'package:vestige/presentation/widgets/empty_state.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

/// 全文搜索页：标题 / 正文 / 标签的包含匹配。
///
/// 放在根导航器上整页推入（和编辑页、回收站一个层级），首页 AppBar 的
/// 放大镜图标进来。搜索是「找一条具体记录」的临时任务，不占底部 tab。
///
/// 交互：输入防抖 280ms 后自动搜；结果卡片与首页同款（多显示一行日期，
/// 因为结果是跨天混杂的）。点卡片进编辑页，回来后按当前关键词重搜一次，
/// 刚改过的内容立刻反映到结果里。
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;

  /// 已经拿到结果的关键词；null = 还没搜过（显示引导页）。
  List<RecordEntity>? _results;
  String _searchedQuery = '';
  bool _searching = false;

  /// 业务日期范围；null = 不限。
  ///
  /// 这里存的是系统选择器给的**闭区间**（含首尾两天）；转成仓储要的
  /// 左闭右开是在 [_run] 里做的。
  DateTimeRange? _range;

  static const Duration _debounceDelay = Duration(milliseconds: 280);

  /// 有没有搜索条件（关键词或日期范围）。都没有 = 显示引导页。
  bool get _hasCondition =>
      _controller.text.trim().isNotEmpty || _range != null;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty && _range == null) {
      // 关键词和范围都没有 = 回到引导页，不再发起查询
      setState(() {
        _results = null;
        _searchedQuery = '';
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(_debounceDelay, () => _run(q));
  }

  Future<void> _run(String q) async {
    final range = _range;
    final results = await ref
        .read(recordRepositoryProvider)
        .searchRecords(
          q,
          from: range?.start,
          // 选择器给的是闭区间（含 end 那天），仓储要的是左闭右开 ——
          // 往后推一天，这样「8/1 到 8/31」才真的涵盖 8/31 一整天。
          to: range?.end.add(const Duration(days: 1)),
        );
    // 防抖/改条件期间用户又改了：这次结果已过期，直接丢弃
    if (!mounted || q != _controller.text.trim() || range != _range) return;
    // 记进历史：**搜过才算**（不是敲字就算），所以放这儿而不是 _onChanged。
    // 有没有结果都记 —— 用户多半是想回看「我刚才找的是哪个词」。
    ref.read(searchHistoryProvider.notifier).remember(q);
    setState(() {
      _results = results;
      _searchedQuery = q;
      _searching = false;
    });
  }

  /// 按某个关键词立刻搜（点历史 chip 用）：绕过防抖。
  void _searchNow(String q) {
    _debounce?.cancel();
    _controller.text = q;
    // 光标挪到末尾：用户想接着改这个词的话，不用先手动定位
    _controller.selection = TextSelection.collapsed(offset: q.length);
    setState(() => _searching = true);
    _run(q);
  }

  /// 选日期范围（点顶部那颗 chip）。
  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 20),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
      helpText: '选择日期范围',
      saveText: '确定',
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
    // 改范围必须重搜：否则屏幕上还是旧范围的结果，和 chip 上写的不一致
    _rerun();
  }

  /// 清掉日期范围。
  void _clearRange() {
    setState(() => _range = null);
    _rerun();
  }

  /// 按当前条件重搜（改范围 / 清范围后用）。
  void _rerun() {
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty && _range == null) {
      setState(() {
        _results = null;
        _searchedQuery = '';
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _run(q);
  }

  Future<void> _openRecord(String id) async {
    await context.push(AppRoutes.editExisting(id));
    // 从编辑页回来：内容可能改过 / 删过，按当前条件重搜一遍
    if (!mounted || !_hasCondition) return;
    _run(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) {
            // 回车 = 不等防抖，立刻搜
            _debounce?.cancel();
            final q = value.trim();
            if (q.isNotEmpty) _run(q);
          },
          decoration: InputDecoration(
            hintText: '搜索标题、正文或标签',
            // 收窄上下留白：主题默认 14 是照着页面里的输入框配的，
            // 顶栏 56 高里会显得过满。
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: '清空',
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
          // 输入变化时刷新 suffixIcon 的显隐
          onTapOutside: (_) => FocusScope.of(context).unfocus(),
        ),
      ),
      body: Column(
        children: <Widget>[
          // 范围条常驻（引导页也显示）：用户可能先框定时间段、再输入关键词，
          // 也可能反过来；而且「现在有没有被范围限制住」得一眼看得出来。
          _RangeBar(range: _range, onPick: _pickRange, onClear: _clearRange),
          Expanded(child: _buildBody(theme, scheme, surfaces)),
        ],
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    ColorScheme scheme,
    VestigeSurfaces surfaces,
  ) {
    final results = _results;
    if (results == null) {
      return _SearchHint(onPick: _searchNow);
    }
    if (results.isEmpty) {
      return _NoResult(query: _searchedQuery);
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Row(
            children: <Widget>[
              Text(
                // 达到上限时必须说清「还有更多」（2026-10-27 审查 m-002）：
                // 仓储侧 `searchActive` 最多返回 kSearchResultLimit 条，
                // 只说「共 N 条结果」会把截断值读成总条数。
                results.length >= kSearchResultLimit
                    ? '已显示前 $kSearchResultLimit 条（还有更多，请加关键词或缩小日期范围）'
                    : '共 ${results.length} 条结果',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_searching) ...<Widget>[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: scheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final record = results[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: RecordCard(
                  record: record,
                  // 结果跨天混杂，徽标多带一行日期（回收站同款）
                  showDay: true,
                  onTap: () => _openRecord(record.id),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 还没输入关键词时的引导页：上面是搜索提示，下面是「最近搜索」。
///
/// 整页可滚：历史最多 10 条，横排换行后在小屏上可能顶出可视区，
/// 不能指望它永远装得下。
class _SearchHint extends ConsumerWidget {
  const _SearchHint({required this.onPick});

  /// 点历史 chip 时回调：把那个词填进输入框并立刻搜（不走防抖）。
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final history = ref.watch(searchHistoryProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 与首页 / 回收站空态同一套写法：图标坐进圆盘，不像「加载失败」。
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.search_rounded,
                size: 36,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '搜索所有记录',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '标题、正文、标签里包含的词都能搜到',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (history.isNotEmpty) ...<Widget>[
            const SizedBox(height: 36),
            _HistoryHeader(
              onClear: () => ref.read(searchHistoryProvider.notifier).clear(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final q in history)
                  InputChip(
                    label: Text(q),
                    // 点词体 = 再搜一次；点小叉 = 只删这一条
                    onPressed: () => onPick(q),
                    onDeleted: () =>
                        ref.read(searchHistoryProvider.notifier).remove(q),
                    deleteIcon: const Icon(Icons.close_rounded, size: 14),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 日期范围的显示文案：`2026/8/1 – 8/31`。
///
/// 同一年时右边省掉年份 —— 窄屏上能短一截。抽成顶层函数是为了能单测：
/// 「跨年要显示年份」这条分支在页面上很难点到。
String searchRangeLabel(DateTimeRange r) {
  final DateTime a = r.start;
  final DateTime b = r.end;
  final left = '${a.year}/${a.month}/${a.day}';
  final right = a.year == b.year
      ? '${b.month}/${b.day}'
      : '${b.year}/${b.month}/${b.day}';
  return '$left – $right';
}

/// 搜索页顶部的日期范围条。
///
/// 用一颗 chip 而不是把范围塞进 AppBar：日期范围是**偶尔用一次**的窄条件，
/// 但必须一眼看出「现在有没有被限制住」—— chip 上的文案就是这个信号
/// （未设范围时写「全部时间」，设了就把区间写出来）。
class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.range,
    required this.onPick,
    required this.onClear,
  });

  final DateTimeRange? range;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = range;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: r == null
            ? ActionChip(
                avatar: const Icon(Icons.date_range_rounded, size: 16),
                label: const Text('全部时间'),
                onPressed: onPick,
                visualDensity: VisualDensity.compact,
              )
            : InputChip(
                avatar: const Icon(Icons.date_range_rounded, size: 16),
                label: Text(searchRangeLabel(r)),
                onPressed: onPick,
                onDeleted: onClear,
                deleteIcon: const Icon(Icons.close_rounded, size: 14),
                visualDensity: VisualDensity.compact,
                selected: true,
                // 选中态加主色描边：这是「当前被范围限制着」的唯一视觉信号
                side: BorderSide(color: scheme.primary, width: 1),
              ),
      ),
    );
  }
}

/// 「最近搜索」小标题 + 右侧的「清空」。
class _HistoryHeader extends StatelessWidget {
  const _HistoryHeader({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Text(
          '最近搜索',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text('清空'),
        ),
      ],
    );
  }
}

/// 搜了但没有命中。
class _NoResult extends StatelessWidget {
  const _NoResult({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    // 空态收敛到共用组件（文案保持原样）；末尾留一截屏高，
    // 让空态在视觉上不顶着底部。
    return Center(
      child: VestigeEmptyState(
        icon: Icons.search_off_outlined,
        title: '没有找到「$query」',
        subtitle: '换个关键词试试，或检查是不是记在了别的标签里',
        trailing: SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
      ),
    );
  }
}
