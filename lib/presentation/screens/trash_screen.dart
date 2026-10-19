import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/record_selection.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/widgets/record_card.dart';

/// 回收站：软删除的记录在这里，可以单条/批量恢复或彻底删除。
/// 回收站里的记录不参与统计。
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  /// 多选态（勾选集 + 显式开关）—— 与首页共用同一份实现，见 [RecordSelection]。
  final RecordSelection _selection = RecordSelection();

  bool get _selectionMode => _selection.isActive;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(trashProvider);
    final records = async.valueOrNull ?? const [];

    // 记录被恢复 / 彻底删除后，清理掉已不存在的选中项。
    // 只读预检放在 build 里、真正的清理扔到 post-frame —— build 期间不该改状态。
    // 这里**不动开关**：哪怕清到最后一条不剩，多选态也留着 ——
    // 退出由用户自己决定（点「取消选择」或按返回），不应代为退出。
    final candidates = records.map((r) => r.id).toSet();
    if (_selection.hasStale(candidates)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _selection.prune(candidates);
        });
      });
    }

    // 整页套一层 [PopScope]：多选态下拦掉系统返回，先退出多选，而不是直接离开回收站。
    // 与首页同一处理 —— 见 home_screen.dart 里的说明。
    final page = Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选 ${_selection.count} 条' : '回收站'),
        // 多选态下左侧是三态全选框（原先是「取消选择」的 ×）。
        // 位置固定、含义明确，与首页多选一致。
        leading: _selectionMode
            ? Padding(
                padding: const EdgeInsets.only(left: 4),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Checkbox(
                    tristate: true,
                    // null = 部分选中。判据是「候选集里每一条都勾上了」，
                    // 不是「勾选数 ≥ 候选数」—— 后者在勾选集混进候选之外的 id 时会误判。
                    value: _selection.triStateOf(candidates),
                    // **不看回调给的 v**：tristate 下它传的是循环下一个值，
                    // 「部分选中」(null) 时点一下拿到的是 false，照它走会变成清空。
                    // 按当前状态决定：已全选才清空，其余一律全选。
                    onChanged: (_) => _toggleSelectAll(candidates),
                    // AppBar 底色是页面底（浅色），描边用 outline 才看得见。
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                      width: 2,
                    ),
                  ),
                ),
              )
            : null,
        actions: _selectionMode
            ? <Widget>[
                // 「已选 0 条」时置灰：多选态现在能停在 0 条上，
                // 不置灰的话点「彻底删除」会弹一个「0 条记录将被永久删除」的确认框。
                IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: '恢复',
                  onPressed: _selection.isEmpty ? null : _restoreSelection,
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_forever_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  tooltip: '彻底删除',
                  onPressed: _selection.isEmpty ? null : _confirmHardDelete,
                ),
                // 取消选择的出口（左侧让给全选框了），也是**按钮里**唯一能退出多选态的那个
                // （另一个出口是系统返回，见 build 末尾的 [PopScope]）。
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '取消选择',
                  onPressed: _exitSelection,
                ),
              ]
            : <Widget>[
                if (records.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    tooltip: '清空回收站',
                    onPressed: _confirmEmptyTrash,
                  ),
              ],
      ),
      body: records.isEmpty
          ? const _TrashEmpty()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: records.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) return const _TrashNotice();
                final record = records[index - 1];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: RecordCard(
                    record: record,
                    showDay: true,
                    selectionMode: true,
                    selected: _selection.contains(record.id),
                    onTap: () => _toggle(record.id),
                    onLongPress: () => _toggle(record.id),
                  ),
                );
              },
            ),
    );

    return PopScope(
      // 多选态下不让路由 pop —— 返回手势先被这里吃掉。
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _exitSelection();
      },
      child: page,
    );
  }

  /// 点卡片 = 勾选 / 取消勾选，同时也是进多选态的入口
  /// （回收站的卡片本来就常驻复选框，所以这里没有「长按进多选」）。
  ///
  /// 具体语义（只开不关、取消最后一条也不退模式）在 [RecordSelection.toggle] 里，
  /// 与首页共用同一份实现。
  void _toggle(String id) => setState(() => _selection.toggle(id));

  /// 退出多选态（显式出口）：关开关 + 清勾选，两件事一起做。
  void _exitSelection() => setState(_selection.exit);

  /// 全选 / 全不选：候选集就是回收站里全部记录（这里没有筛选，所见即全部）。
  ///
  /// 「全不选」只清勾选、不关多选态 —— 理由见 [RecordSelection.toggleAll]。
  void _toggleSelectAll(Iterable<String> candidates) =>
      setState(() => _selection.toggleAll(candidates));

  Future<void> _restoreSelection() async {
    final ids = _selection.snapshot();
    _exitSelection();
    await ref.read(recordActionsProvider).restoreRecords(ids);
    if (!mounted) return;
    _toast('已恢复 ${ids.length} 条');
  }

  Future<void> _confirmHardDelete() async {
    final count = _selection.count;
    final confirmed = await _confirm(
      title: '彻底删除？',
      message: '$count 条记录将被永久删除，无法恢复。',
      confirmLabel: '彻底删除',
      destructive: true,
    );
    // 用户点了取消：什么都不做，勾选原样留着。
    if (confirmed != true) return;
    final ids = _selection.snapshot();
    _exitSelection();
    await ref.read(recordActionsProvider).hardDeleteRecords(ids);
    if (!mounted) return;
    _toastUndoable('已彻底删除 $count 条');
  }

  Future<void> _confirmEmptyTrash() async {
    final confirmed = await _confirm(
      title: '清空回收站？',
      message: '回收站里的所有记录将被永久删除，无法恢复。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (confirmed != true) return;
    final count = await ref.read(recordActionsProvider).emptyTrash();
    if (!mounted) return;
    _toastUndoable('已清空 $count 条');
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              confirmLabel,
              style: destructive ? TextStyle(color: scheme.error) : null,
            ),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 显示一条**带「撤销」**的提示（可撤销的操作都用它）。
  ///
  /// 撤销的是历史里最新那一步，也就是刚做的那一步 —— 每条提示都会先收掉上一条，
  /// 所以屏幕上这条永远对应最新的一步。与首页同一套做法。
  ///
  /// 时长 3 秒（与首页同一档）：撤销历史保留 20 步且不过期，错过这个窗口
  /// 还能去「操作历史」退，所以提示条不必久留。
  ///
  /// `persist: false` **必须显式给出**：`SnackBar.persist` 默认是 `action != null`，
  /// 带按钮的提示条默认**永不自动消失**，duration 会被忽略
  /// （见 material/snack_bar.dart 里 persist 的文档）。
  void _toastUndoable(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          persist: false,
          action: SnackBarAction(label: '撤销', onPressed: _undoLatest),
        ),
      );
  }

  /// 撤销最近一步。
  ///
  /// 这里最有用的一档是「**清空回收站之后后悔**」：快照里带着完整字段，
  /// 撤销会把那些记录原样插回来。
  Future<void> _undoLatest() async {
    final actions = ref.read(recordActionsProvider);
    final history = await actions.recentUndo();
    if (history.isEmpty || !mounted) return;

    final restored = await actions.undoUpTo(history.first.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _toast(restored == 0 ? '没有可回滚的内容' : '已撤销，$restored 条记录回到操作前');
  }
}

class _TrashNotice extends StatelessWidget {
  const _TrashNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '回收站中的记录不计入统计；点击卡片可多选。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrashEmpty extends StatelessWidget {
  const _TrashEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // 与首页空态同一套写法：图标坐进圆盘，空态才不像「加载失败」。
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: surfaces.inset,
              shape: BoxShape.circle,
              border: Border.all(color: surfaces.border),
            ),
            child: Icon(Icons.delete_outline, size: 34, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          Text(
            '回收站是空的',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '删掉的记录会先落到这里，可以随时恢复',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
