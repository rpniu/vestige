import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/undo_dao.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

/// 把时刻说成人话。抽成带 `now` 参数的纯函数是为了能单测 ——
/// 直接读 `DateTime.now()` 的写法在测试里没法稳定断言。
String undoAgoLabel(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.isNegative || d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${at.year}/${at.month}/${at.day}';
}

/// 操作历史：最近几步可撤销的操作，可以回退到任意一步**之前**。
///
/// 为什么要有这个入口，而不是只靠 SnackBar 上的「撤销」：
/// SnackBar 只够退最近一步，而真正需要回退的场景往往发生在**提示消失之后**
/// （甚至第二天才反应过来）。历史落库也是为这件事 —— 见 `undo_entry.dart`。
///
/// 回退语义：点第 N 步 = 第 N 步**以及比它更新的步骤一起**回滚。
/// 这是唯一自洽的做法：历史是一条链，中间抽掉一环，后面的状态就对不上了。
///
/// 删除（单条 / 清空）：**只抹掉回退点，不动任何记录数据** ——
/// 与条数上限、时间清理是同一原则（删历史 ≠ 删数据）。
/// 回退取的是「最旧快照整行写回」，所以删掉中间某一步也不会让
/// 更早的回退结果变味，仅仅是「无法再退到那一步之前」。
///
/// 承载方式：本组件最初是「我的 → 操作历史」弹出的居中弹层，现已改为由
/// [UndoHistoryScreen] 以整页形式承载（见该页说明）。内容组件本身不变 ——
/// 标题行（左「操作历史」+ 右「清空」）仍由这里出，页面侧的 AppBar 只给
/// 返回箭头、不重复写标题；行的渲染与交互因此只有这一份实现。
class UndoHistorySheet extends ConsumerStatefulWidget {
  const UndoHistorySheet({super.key});

  @override
  ConsumerState<UndoHistorySheet> createState() => _UndoHistorySheetState();
}

class _UndoHistorySheetState extends ConsumerState<UndoHistorySheet> {
  late Future<List<UndoEntryEntity>> _future = _load();

  Future<List<UndoEntryEntity>> _load() =>
      ref.read(recordActionsProvider).recentUndo();

  /// [newerCount] 是排在它前面（更新）的步数 —— 一并回滚时要说清楚。
  Future<void> _rollback(UndoEntryEntity entry, int newerCount) async {
    if (newerCount > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('一并回退更新的操作？'),
          content: Text(
            '「${entry.label}」之后还有 $newerCount 步操作。\n'
            '历史是一条链，中间抽掉一环，后面的状态就对不上了，'
            '所以它们会被一起回退。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('一并回退'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final restored = await ref.read(recordActionsProvider).undoUpTo(entry.id);
    if (!mounted) return;

    // 列表要重刷：被回滚掉的条目已经从历史里删了。
    // 注意用块体而不是 `() => _future = _load()` —— 赋值表达式的值是 Future，
    // 箭头函数会把它返回出去，`setState` 会直接抛
    // 「setState() callback argument returned a Future」。
    setState(() {
      _future = _load();
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已回退，$restored 条记录回到操作前')));
  }

  /// 删除单条历史。**不弹确认** —— 删的只是一个回退点，记录数据分毫不动
  /// （与条数上限/时间清理同一原则），为它打断一次操作流不值得。
  Future<void> _deleteEntry(UndoEntryEntity entry) async {
    await ref.read(recordActionsProvider).deleteUndoEntry(entry.id);
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
    _toast('已删除「${entry.label}」的历史，记录不受影响');
  }

  /// 清空全部历史。这个要二次确认：一次抹掉最多 [kUndoHistoryLimit] 个
  /// 回退点，虽然不伤数据，但「想撤销时才发现没了」比单条删除痛得多。
  Future<void> _confirmClearAll() async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空操作历史？'),
        content: const Text(
          '只是删掉这些回退点，记录数据不受任何影响；'
          '但之后这些操作将无法再撤销。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await ref.read(recordActionsProvider).clearUndoHistory();
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
    _toast('已清空操作历史');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // FutureBuilder 包住整个内容而不是只包列表：标题行的「清空」入口
    // 要知道「现在有没有历史」才能决定显不显示。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: FutureBuilder<List<UndoEntryEntity>>(
          future: _future,
          builder: (
            BuildContext context,
            AsyncSnapshot<List<UndoEntryEntity>> snap,
          ) {
            final entries = snap.data;
            final hasEntries = entries != null && entries.isNotEmpty;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 标题行 = 弹层统一语言：左标题 + 右侧动作
                Row(
                  children: <Widget>[
                    Text(
                      '操作历史',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    if (hasEntries)
                      TextButton(
                        onPressed: _confirmClearAll,
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('清空'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '最近 $kUndoHistoryLimit 步可回退 · 点某一步会连同它之后的操作'
                  '一起回退；删除只是抹掉回退点，记录数据不受影响',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                // 列表不写死高度：外层 Column 一旦含有 flex 子项，就会先满足
                // 非 flex 子项、再把剩余高度分给 flex 的这一个 —— 整页下
                // Scaffold body 给的是紧约束，于是列表自动吃满剩下的整屏高度。
                //
                // 这里不用 Expanded：Expanded 的 fit 是 tight，在外层高度无界时
                // 直接抛错；用 Flexible（loose）则在两种承载下都成立。
                //
                // 弹层时期这里是「定高 = 屏高 × 0.8 + shrinkWrap 列表」——
                // 弹层高度由内容撑出（无界），只有 shrinkWrap 能定高。换成整页后
                // 父级高度确定，把空间让给列表才合理，于是 _buildList 里也去掉了
                // shrinkWrap：普通 ListView 在有界约束下自己就能滚，且更省。
                Flexible(
                  // hasError 必须先于「data == null」判定：Future 出错时
                  // data 同样是 null，先判空会把错误吞成无限转圈 ——
                  // 用户看到的就是一个永远停不下来的加载圈。
                  child: snap.hasError
                      ? _buildError(theme, scheme, snap.error)
                      : _buildList(entries, theme, scheme),
                ),
              ],
            );
          },
        ),
    );
  }

  /// 加载失败态：说清发生了什么、给一次重试。
  ///
  /// 数据库打不开（迁移失败、文件损坏等）在这里就是「永远转圈」，
  /// 所以错误必须显眼地露出来 —— 哪怕用户看不懂细节，
  /// 「重试」按钮也给了他一个出口，报障时截图里的错误信息也能定位问题。
  Widget _buildError(ThemeData theme, ColorScheme scheme, Object? error) {
    // 居中：整页下这块区域是满屏高，错误信息贴顶会显得像「页面没加载完」，
    // 居中才读得出「这里就是结果」。
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '历史加载失败',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.error,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$error',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _future = _load();
              }),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
    List<UndoEntryEntity>? entries,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      // 顶端对齐：空态说明和列表第一行的起始位置一致，视线不用跳。
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            '还没有可回退的操作。\n批量打标签、平移日期、移入回收站、'
            '彻底删除、清空回收站都会记在这里。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
      );
    }
    // 不再用 shrinkWrap：外层是 Flexible，拿到的约束是「有界」的，
    // 普通 ListView 直接吃满这块高度并自行滚动 —— 这也是整页承载想要的效果。
    // shrinkWrap 只在「高度无界、需要让列表按内容定高」时才必要（弹层时期）。
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 0),
      itemBuilder: (BuildContext context, int i) {
        final e = entries[i];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            e.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            '${undoAgoLabel(e.createdAt, DateTime.now())}'
            ' · 影响 ${e.recordCount} 条',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          // i 就是「比它更新的步数」：列表是新的在前
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除这条历史',
                visualDensity: VisualDensity.compact,
                onPressed: () => _deleteEntry(e),
              ),
              TextButton(
                onPressed: () => _rollback(e, i),
                child: const Text('回退'),
              ),
            ],
          ),
        );
      },
    );
  }
}
