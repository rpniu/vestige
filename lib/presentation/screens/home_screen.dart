import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/motion.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/domain/duration_format.dart';
import 'package:vestige/domain/record_selection.dart';
import 'package:vestige/data/config/home_layout_config.dart';
import 'package:vestige/presentation/providers/duration_timer_provider.dart';
import 'package:vestige/presentation/providers/home_layout_provider.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/widgets/batch_tag_sheet.dart';
import 'package:vestige/presentation/widgets/entrance.dart';
import 'package:vestige/presentation/widgets/error_state.dart';
import 'package:vestige/presentation/widgets/center_dialog.dart';
import 'package:vestige/presentation/widgets/record_card.dart';
import 'package:vestige/presentation/widgets/row_metrics.dart';
import 'package:vestige/presentation/providers/home_scroll_provider.dart';

/// 首页：按「归属日期」分组的记录列表。
///
/// 补记在这里有两个入口：
/// 1. 右下角「记一笔」进编辑页，在「今天 / 补交」里选择是否补交，再挑具体日期；
/// 2. 长按任意卡片多选 —— 批量把选中的记录日期前后平移一天（漏记一整天时最省事）。
///
/// 另有两个浮层按钮（与「记一笔」竖着叠成一列，整列停靠边可由
/// `<数据目录>/config/home_buttons.json` 配置，见 [ButtonSide]）：
/// - 「速记」：不进编辑页，直接记一条内容为「速记」的今日记录（见 [_QuickNoteButton]）；
/// - 「到顶 / 到底」：列表滑动时浮现，方向跟着用户的滑动方向走（见 [ScrollJumpButton]）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// 多选态（勾选集 + 显式开关）—— 与回收站共用同一份实现，见 [RecordSelection]。
  /// 之所以不在两个页面各写一遍 `Set<String>` + `bool`：那样改一处忘一处就会跑偏，
  /// 2026-09-23 那个「取消全选直接退出多选」的 bug 正是这么来的。
  final RecordSelection _selection = RecordSelection();

  final ScrollController _scrollController = ScrollController();

  bool get _selectionMode => _selection.isActive;

  /// 每行的行高，**预计算**成数组（见 [build] 里 `itemExtentBuilder` 的说明）。
  /// 只在「行列表变了」或「字号变了」时重算：前者由 provider 的对象身份判定，
  /// 后者由缩放系数判定。
  Float64List? _extents;
  List<HomeRow>? _extentsComputedFor;
  double _extentsScale = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 预计算每行的行高。为什么值得多这一层：
  ///
  /// `RenderSliverVariedExtentList` 要**从头累加**行高才知道目标偏移落在第几行，
  /// 所以 `itemExtentBuilder` 每一帧会被调用 **O(当前 index) 次**
  /// （滚到第 5000 行时，每帧几千次）。回调里一旦有 `switch`、`title.trim()`
  /// 这类活，就被乘上了「当前滚到第几行」—— 必须只剩一次数组读取。
  ///
  /// 顺带：这也让「行高怎么算」的决定权留在这一处，不在每帧执行的热路径上。
  Float64List _extentsOf(
    List<HomeRow> rows,
    double scale,
    double headerExtent,
    double fullExtent,
    double denseExtent,
  ) {
    final cached = _extents;
    if (cached != null &&
        identical(rows, _extentsComputedFor) &&
        scale == _extentsScale) {
      return cached;
    }
    final out = Float64List(rows.length);
    for (var i = 0; i < rows.length; i++) {
      out[i] = switch (rows[i]) {
        DayHeaderRow() => headerExtent,
        // 档位判定与卡片内部渲染共用 `isDenseCard`，两边不会对不上。
        RecordRow(:final record) =>
          record.isDenseCard ? denseExtent : fullExtent,
      };
    }
    _extents = out;
    _extentsComputedFor = rows;
    _extentsScale = scale;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(homeRowsProvider);
    // 按钮列停靠边（见 home_layout_provider）：三颗按钮一整列同侧，
    // Notifier 的同步 state，文件加载完成后原地覆盖，「我的」页改动即时生效。
    final side = ref.watch(homeButtonLayoutProvider);
    final recordsAsync = ref.watch(recordsProvider);
    // 「今天是哪天」每次构建只算一次，传给所有分组头 —— 这样每个头都是纯整数运算，
    // 不会为了一天去构造本地 DateTime（见 day_util 里的性能说明）。
    final now = DateTime.now();
    final todayNumber = dayNumber(now);
    // 标题第二行：「距上次记录 N 天」。同样是整数减法，不构造 DateTime。
    final lastDay = ref.watch(lastRecordedDayProvider);
    final gapDays = lastDay == null ? null : todayNumber - lastDay;
    // 行高也是每次构建算一次（只读 MediaQuery，很便宜），交给下面 sliver 声明。
    // 两档：只有正文的「秒记」行用紧凑档，带标题/标签/补记的行用完整档
    // （详见 VestigeRowMetrics 与 RecordCardShapeX）。
    final headerExtent = VestigeRowMetrics.headerExtent(context);
    final fullExtent = VestigeRowMetrics.cardExtent(context, dense: false);
    final denseExtent = VestigeRowMetrics.cardExtent(context, dense: true);
    final extents = _extentsOf(
      rows,
      VestigeRowMetrics.textScale(context),
      headerExtent,
      fullExtent,
      denseExtent,
    );
    // 标签：一个标签都没有时 AppBar 上不放那个入口按钮（点了只会弹一个空弹层）。
    final tagCounts = ref.watch(tagCountsProvider);
    // 实际生效的勾选（已剔除那些随记录一起消失的标签）。
    final activeTags = ref.watch(effectiveTagFilterProvider);
    final isFiltering = activeTags.isNotEmpty;
    // 入口按钮的 tooltip：单个标签直接把名字说出来，多个就报到个数 ——
    // 「筛选：#咖啡、#工作、#生活」长到看不清，tooltip 又不是展示标签的地方。
    final filterLabel = !isFiltering
        ? '按标签筛选'
        : activeTags.length == 1
        ? '筛选：#${activeTags.first}'
        : '筛选：已选 ${activeTags.length} 个标签';

    // 底部导航「主页」图标被再次点击 → 回到顶部 + 重订阅数据流（刷新）。
    // 计数 provider 由 router 的 _ShellScaffold 递增，这里消费。
    ref.listen<int>(homeTopRequestProvider, (previous, next) {
      if (next > (previous ?? 0)) _goTopAndRefresh();
    });

    // 多选态下 AppBar 左侧是三态全选框（原先是「取消选择」的 ×）：
    // 位置固定、含义明确 —— 素材列表/相册/邮件这些多选界面都把它放这儿，
    // 用户不用学。退出多选有三个出口：系统返回手势（见 build 末尾的 [PopScope]）、
    // 标题右侧的收起按钮、批量操作执行完之后。
    //
    // 候选集 = 「当前屏幕上看得见的这些」。它同时是三态全选框的判据和剪枝的依据 ——
    // 勾选集必须始终是候选集的子集，否则「移入回收站」会删掉用户没看见的记录。
    final candidates = _selectableIdsOf(rows);

    // 记录被删掉、或被标签筛掉之后，把失效的勾选清掉。
    // 放在 build 里而不是写数据的地方：候选集是**派生**的，只有 build 知道它现在是什么。
    // 只读预检在 build 里做，真正的清理扔到 post-frame —— build 期间不该改状态。
    if (_selection.hasStale(candidates)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _selection.prune(candidates);
        });
      });
    }

    // 整页套一层 [PopScope]：多选态下拦掉系统返回，先退出多选，而不是直接离开首页。
    // 没有这一层的话，多选态会一直留着（「取消全选」不再自动退出），
    // 用户按返回就会意外离开首页 —— 这是「多选态改成显式开关」连带引入的问题。
    final page = Scaffold(
      appBar: AppBar(
        // 标题不再是 App 名「Vestige」，而是「今天是哪天 + 距上次记录多久」：
        // App 名对每天都打开的人没有信息量，日期和「隔了几天」才是这一屏的时间锚点。
        title: _selectionMode
            ? Text('已选 ${_selection.count} 条')
            : _HomeTitle(date: fullDateLabel(now), gapDays: gapDays),
        leading: _selectionMode
            ? Padding(
                padding: const EdgeInsets.only(left: 4),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Checkbox(
                    tristate: true,
                    // null = 部分选中（选了至少一条但没全选），白色勾选框里的那一横
                    // 就是「还差一些」的信号。
                    value: _selection.triStateOf(candidates),
                    onChanged: (_) => _toggleSelectAll(rows),
                    // AppBar 底色是本 App 的页面底（浅色），不是主色 ——
                    // 未选中的方框用 outline 描边才看得见（onPrimary 在这儿是白线）。
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
                // 四个批量按钮在「已选 0 条」时置灰。
                // 多选态现在能停在 0 条上（取消全选之后就是），不置灰的话
                // 点「移入回收站」会拿着空 id 列表跑一遍，还弹一句「已移入回收站（0 条）」。
                //
                // 设计约定（2026-10-22 图标优化）：
                // - 「日期平移」不用 undo/redo 图标 —— 那两枚全世界都读作
                //   「撤销/重做」，和本 App 的撤销体系（SnackBar / 操作历史）撞车。
                //   换成双向箭头：方向即含义，tooltip 补足「动的是日期」。
                // - 四枚图标统一实底 rounded 家族，字重一致。
                // - 移入回收站是唯一破坏性操作，可用态给 error 色。
                IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
                  tooltip: '日期减一天',
                  onPressed: _selection.isEmpty
                      ? null
                      : () => _shiftSelection(-1),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                  tooltip: '日期加一天',
                  onPressed: _selection.isEmpty
                      ? null
                      : () => _shiftSelection(1),
                ),
                IconButton(
                  icon: const Icon(Icons.sell_rounded),
                  color: _selection.isEmpty
                      ? null
                      : Theme.of(context).colorScheme.primary,
                  tooltip: '批量打标签',
                  onPressed: _selection.isEmpty ? null : _openBatchTagSheet,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_rounded),
                  color: _selection.isEmpty
                      ? null
                      : Theme.of(context).colorScheme.error,
                  tooltip: '移入回收站',
                  onPressed: _selection.isEmpty ? null : _deleteSelection,
                ),
                // 取消选择的出口：左侧位置让给了全选框，这里补一个「收起」。
                // 全选框（清勾选）和逐条取消勾选都只动勾选集、不关开关，
                // 所以这是**按钮里**唯一能退出多选态的那个（另一个出口是系统返回）。
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '取消选择',
                  onPressed: _clearSelection,
                ),
              ]
            : <Widget>[
                // 标签筛选的入口。标签**不铺在主页上**（原来那排 chip 占了 48px
                // 常驻高度，而且标签一多就得横滑着找），改为点开一个模态弹层慢慢挑。
                // 有筛选生效时按钮换成实心的标签图标 + 主色，不进弹层也知道现在被筛着。
                if (tagCounts.isNotEmpty)
                  IconButton(
                    icon: Icon(
                      isFiltering ? Icons.sell_rounded : Icons.sell_outlined,
                    ),
                    color: isFiltering
                        ? Theme.of(context).colorScheme.primary
                        : null,
                    tooltip: filterLabel,
                    onPressed: _openTagSheet,
                  ),
                IconButton(
                  icon: const Icon(Icons.search_rounded),
                  tooltip: '搜索',
                  onPressed: () => context.push(AppRoutes.search),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep_rounded),
                  tooltip: '回收站',
                  onPressed: () => context.push(AppRoutes.trash),
                ),
              ],
      ),
      floatingActionButton: _selectionMode ? null : const _NewRecordFab(),
      // 左右停靠由配置决定（「我的」页可改，持久化在
      // <数据目录>/config/home_buttons.json，见 [ButtonSide]）。
      floatingActionButtonLocation:
          ref.watch(homeButtonLayoutProvider) == ButtonSide.left
          ? FloatingActionButtonLocation.startFloat
          : FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: <Widget>[
          RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(recordsProvider);
              await ref.read(recordsProvider.future);
            },
            child: CustomScrollView(
              controller: _scrollController,
              slivers: <Widget>[
                // 筛选生效时才出现的一行细指示条：告诉用户「你现在看的不是全部」，
                // 并给一个一键清除的落点。没筛选时它整条不存在 ——
                // 常驻一排标签 chip 的时代结束了（见 AppBar 的 _openTagSheet）。
                if (isFiltering)
                  SliverToBoxAdapter(
                    child: _ActiveTagBanner(
                      tags: activeTags,
                      // 条数按「并集」重算：勾了咖啡 + 工作，两个标签各自的条数加起来
                      // 会把同时贴了这两个标签的记录数两遍（见 filteredRecordCountProvider）。
                      count: ref.watch(filteredRecordCountProvider),
                      onClear: () =>
                          ref.read(selectedTagsProvider.notifier).clear(),
                      onRemove: (tag) =>
                          ref.read(selectedTagsProvider.notifier).toggle(tag),
                    ),
                  ),
                // 错误态必须排在「空态」之前：库打不开 / 迁移失败时 rows 同样是空的，
                // 落到空态就会显示「还没有任何记录」—— 与数据真的没了无法区分
                // （见 VestigeErrorState 的说明，2026-10-27 审查 C-001）。
                if (recordsAsync.hasError)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: VestigeErrorState(
                      error: recordsAsync.error!,
                      onRetry: () => ref.invalidate(recordsProvider),
                    ),
                  )
                else if (recordsAsync.isLoading && rows.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (rows.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(),
                  )
                else ...<Widget>[
                  // 分组头与卡片在**同一个** sliver 里，逐行惰性构建：
                  // 一天有多少条都只建屏幕内的那几张（见 homeRowsProvider 的说明）。
                  //
                  // 用的是 `SliverVariedExtentList` 而不是 `SliverList`：行高由
                  // `itemExtentBuilder` **声明**，渲染对象于是能算术定位到目标 index，
                  // 不用为了知道「第 3000 行在哪个偏移」而把前 2999 行逐个构建一遍。
                  // 「一键到底」的跳转成本因此从 O(总行数) 掉到 O(可见行)：
                  // 6000 条记录时，跳转首帧的构建量从约 4500 行降到恒定 20 行
                  // （实测见 test/perf/scroll_jump_bench_test.dart，
                  // 回归看 test/widget/home_fixed_row_test.dart）。
                  //
                  // 行高的唯一来源是 VestigeRowMetrics，卡片渲染读的是同一份常量，
                  // 所以「声明的行高」和「卡片实际高度」不会对不上。
                  SliverVariedExtentList.builder(
                    itemCount: rows.length,
                    // 行高数组已在 build 里预计算好（见 _extentsOf 里的性能说明）。
                    // 越界必须返回 null，否则渲染对象会一直往下问。
                    itemExtentBuilder: (index, _) =>
                        index < extents.length ? extents[index] : null,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return switch (row) {
                        // 分组头靠下对齐（它标的是它下面那几行属于哪天），
                        // 上留白含在 headerExtent 里。
                        // 左边距与卡片对齐（都用 sidePadding），分组头的竖条
                        // 于是和卡片左边缘在同一条垂线上；下边距 12 见
                        // VestigeRowMetrics.headerChrome 的说明。
                        DayHeaderRow(:final group) => Padding(
                          padding: const EdgeInsets.fromLTRB(
                            VestigeRowMetrics.sidePadding,
                            0,
                            16,
                            12,
                          ),
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: _DayHeader(
                              group: group,
                              todayNumber: todayNumber,
                            ),
                          ),
                        ),
                        RecordRow(:final record) => Padding(
                          padding: const EdgeInsets.fromLTRB(
                            VestigeRowMetrics.sidePadding,
                            0,
                            VestigeRowMetrics.sidePadding,
                            VestigeRowMetrics.gap,
                          ),
                          // 首屏前 8 行做一次性 stagger 入场（30ms/行，见
                          // [VestigeEntrance]）；之后滚到的行直接出现，不重播。
                          // 入场只动透明度/位移，不参与布局，行高声明不受影响。
                          child: index < 8
                              ? VestigeEntrance(
                                  delay: Duration(milliseconds: 30 * index),
                                  child: RecordCard(
                                    record: record,
                                    selected: _selection.contains(record.id),
                                    selectionMode: _selectionMode,
                                    onTap: () => _onTapRecord(record.id),
                                    onLongPress: () => _toggle(record.id),
                                  ),
                                )
                              : RecordCard(
                                  record: record,
                                  selected: _selection.contains(record.id),
                                  selectionMode: _selectionMode,
                                  onTap: () => _onTapRecord(record.id),
                                  onLongPress: () => _toggle(record.id),
                                ),
                        ),
                      };
                    },
                  ),
                  // 给右下角 FAB / 滑动按钮留出空间
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ],
            ),
          ),
          // 快捷胶囊 dock（2026-10-22 用户定稿）：速记 / 计时 收在一枚
          // 竖向胶囊里，悬在 FAB 正上方 —— 两段共用一个容器、一层投影。
          // 多选态下速记段整体收起（dock 变矮），计时段保留 ——
          // 它代表一件还没收尾的事，收起会让用户忘了停。
          _floatPositioned(
            side: side,
            bottom: _dockBottom,
            child: _QuickDock(showQuickNote: !_selectionMode),
          ),
          // 「到底」：屏幕下缘居中的临时按钮，滑动列表时淡入、停手收起
          // （见 [_ToBottomButton]）。「到顶」不在按钮上 —— 主页图标再点即回顶。
          Positioned(
            left: 0,
            right: 0,
            bottom: _toBottomBottom,
            child: Center(
              child: _ToBottomButton(controller: _scrollController),
            ),
          ),
        ],
      ),
    );

    return PopScope(
      // 多选态下不让路由 pop —— 返回手势先被这里吃掉。
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        // 真的 pop 掉了（非多选态）就什么都不用做。
        if (didPop) return;
        _clearSelection();
      },
      child: page,
    );
  }

  /// 打开标签筛选弹层。
  ///
  /// 勾选直接写回 [selectedTagsProvider] —— 弹层**不 pop 传值**，
  /// 这样用户可以连着勾几个标签，一边看背后那份列表怎么收窄，最后手动关掉。
  /// 传值式（pop(selected)）只能选一次就关，用来「挑一个」很顺、用来「逛一遍」很烦。
  ///
  /// [tagSheetOpenProvider] 是给 AppBar 那个入口按钮看的（弹层开着时按钮变实心），
  /// 两者不在同一层 widget 树里，只能走 provider。
  Future<void> _openTagSheet() async {
    ref.read(tagSheetOpenProvider.notifier).state = true;
    await showVestigeCenterDialog<void>(
      context: context,
      // 标签可能上百个，列表自己在弹层里滚（内容组件自带高度约束）。
      // 屏高八成：标签一多六成太挤，翻起来费劲（年份/操作历史同此尺寸）。
      builder: (BuildContext context) => const _TagSheet(),
      maxHeightFactor: 0.8,
    );
    if (!mounted) return;
    ref.read(tagSheetOpenProvider.notifier).state = false;
  }

  void _onTapRecord(String id) {
    if (_selectionMode) {
      _toggle(id);
    } else {
      context.push(AppRoutes.editExisting(id));
    }
  }

  /// 长按卡片 = 进多选并勾上；多选态下点卡片 = 勾选 / 取消勾选。
  ///
  /// 具体语义（只开不关、取消最后一条也不退模式）在 [RecordSelection.toggle] 里，
  /// 与回收站共用同一份实现。
  void _toggle(String id) {
    // 多选进入/切换的「确认感」触觉；桌面端自动无效。
    HapticFeedback.selectionClick();
    setState(() => _selection.toggle(id));
  }

  /// 底部导航「主页」图标被再次点击：回到顶部 + 刷新一次数据流。
  ///
  /// 刷新的实现是 `ref.invalidate(recordsProvider)` —— 重订阅 `watchAllRecords()`
  /// 流，等于对库再做一次查询；Riverpod 2 在重订阅期间保留上一次的值
  /// （AsyncLoading 携带旧值），列表不会闪一帧空白。
  /// 数据本身是 drift 的响应式流，写入早已实时推送 —— 这里的刷新是给
  /// 「怀疑页面没更新」的用户一个明确的、可感知的重载动作。
  void _goTopAndRefresh() {
    HapticFeedback.selectionClick();
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    ref.invalidate(recordsProvider);
  }

  /// 当前列表里**可被选中的**记录 id（分组头不算）。
  ///
  /// 全选的候选集取的是 `homeRowsProvider` —— 也就是**屏幕上正看着的这些**，
  /// 而不是全库记录。理由：用户先按标签筛到「咖啡」，再点全选，
  /// 意思是「把这些咖啡记录都处理掉」，绝不会是想把没显示出来的记录也拖下水。
  /// 批量删除这类操作不可逆，多选一个没看见的记录就是事故。
  ///
  /// 这个集合同样是 [RecordSelection.prune] 的依据（见 build），
  /// 所以勾选集永远是它的子集 —— 全选框的判据和实际能操作的集合不会脱节。
  ///
  /// 候选集由调用方把**本帧的 rows 传进来**（2026-10-27 审查 m-007）：原先是
  /// `ref.read(homeRowsProvider)`，依赖「build 里已经 watch 过、值已就绪」这条
  /// 隐式时序 —— 读得太早就会拿到上一帧或空集。
  Set<String> _selectableIdsOf(List<HomeRow> rows) => <String>{
    for (final row in rows)
      if (row is RecordRow) row.record.id,
  };

  /// 全选 / 全不选（同一按钮来回切，AppBar 上只占一个位置）。
  ///
  /// 「全不选」只清勾选、不关多选态 —— 理由见 [RecordSelection.toggleAll]。
  void _toggleSelectAll(List<HomeRow> rows) =>
      setState(() => _selection.toggleAll(_selectableIdsOf(rows)));

  /// 退出多选态（显式出口）：关开关 + 清勾选，两件事一起做。
  ///
  /// 批量操作（移入回收站 / 平移日期）执行完也走这里 ——
  /// 操作做完了，多选态就没有存在意义，顺势收掉。
  void _clearSelection() => setState(_selection.exit);

  Future<void> _deleteSelection() async {
    final ids = _selection.snapshot();
    _clearSelection();
    await ref.read(recordActionsProvider).deleteRecords(ids);
    if (!mounted) return;
    _toastUndoable('已移入回收站（${ids.length} 条）');
  }

  /// 批量打标签：先弹层选「哪些标签 + 加上还是去掉」，再落到数据层。
  ///
  /// 弹层返回 null（用户点遮罩 / 按返回关掉）时**什么都不做** ——
  /// 关掉弹层不等于确认，这条如果搞错，用户会被一次误操作改掉一批记录。
  Future<void> _openBatchTagSheet() async {
    final count = _selection.count;
    if (count == 0) return;

    final result = await showVestigeCenterDialog<BatchTagResult>(
      context: context,
      // 标签可能上百个，chip 区自己在弹层里滚（与标签筛选弹层同款处理）。
      builder: (BuildContext context) => BatchTagSheet(count: count),
    );
    if (result == null || !mounted) return;

    final ids = _selection.snapshot();
    _clearSelection();
    final changed = await ref
        .read(recordActionsProvider)
        .applyTags(ids, add: result.add, remove: result.remove);
    if (!mounted) return;

    if (changed == 0) {
      // 加的是本来就在的标签（或去的是本来就没有的）—— 说清楚没改动，
      // 否则用户会以为按钮坏了。
      _toast('这 $count 条的标签本来就是这样，没有改动');
      return;
    }
    final adding = result.add.isNotEmpty;
    final tags = (adding ? result.add : result.remove).toList()..sort();
    final label = tags.map((String t) => '#$t').join(' ');
    _toastUndoable('已给 $changed 条记录${adding ? '加上' : '去掉'} $label');
  }

  /// 批量平移日期 —— 漏记了一整天的场景：选中当天的记录，整体 +1 天。
  Future<void> _shiftSelection(int deltaDays) async {
    final ids = _selection.snapshot();
    _clearSelection();
    await ref.read(recordActionsProvider).shiftDay(ids, deltaDays);
    if (!mounted) return;
    _toastUndoable('${ids.length} 条记录的日期已${deltaDays > 0 ? '后' : '前'}移 1 天');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 显示一条**带「撤销」**的提示（可撤销的操作都用它）。
  ///
  /// 撤销的目标是**这次操作刚刚写下的那条 undo 记录**（`lastUndoEntryId`），
  /// 不是「历史里最新的一步」。这两者在多数时候相同，但有一个致命的分歧：
  /// 当操作本身没有产生历史条目时（快照为空 —— 例如硬删除一批已不存在的 id），
  /// 「退最新一步」会退掉**上一个不相关的操作**（2026-10-27 审查 M-007）。
  /// 所以这里先问一句「刚才真的记下历史了吗」，没记就退化成普通提示。
  ///
  /// 时长 3 秒：够看清、够反应过来，又不占着屏幕碍事。
  /// **敢给这么短是因为有兜底** —— 撤销历史保留最近 20 步且不过期，
  /// 这个窗口错过了还有「操作历史」能退，所以不必把提示条钉在屏幕上等用户。
  ///
  /// `persist: false` **必须显式给出**：`SnackBar.persist` 的默认值是
  /// `action != null` —— 也就是**带按钮的提示条默认永不自动消失**，
  /// 上面那 3 秒会被完全忽略（见 material/snack_bar.dart 里 persist 的文档）。
  /// 加了这个 action 就必须同时显式关掉 persist，否则提示会一直挂在屏幕上。
  void _toastUndoable(String message) {
    final entryId = ref.read(recordActionsProvider).lastUndoEntryId;
    if (entryId == null) {
      // 没有可回退的条目：不挂按钮，避免点了却退掉别的操作。
      _toast(message);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // 撤销类提示统一带主色撤销图标：和普通 toast 在视觉上分级。
          //（本版 SnackBar 没有 icon 参数，图标并进 content 行首。）
          content: Row(
            children: <Widget>[
              Icon(
                Icons.undo_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          duration: const Duration(seconds: 3),
          persist: false,
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoEntry(entryId),
          ),
        ),
      );
  }

  /// 撤销**指定的那一步**（以及比它更新的步骤，见 `undoUpTo` 的语义）。
  ///
  /// 同时收起提示：否则用户连点两次「撤销」，第二下会退到更早的一步 ——
  /// 那时屏幕上那条提示已经不描述那一步了，属于「撤销了意料之外的东西」。
  Future<void> _undoEntry(int entryId) async {
    final actions = ref.read(recordActionsProvider);
    final restored = await actions.undoUpTo(entryId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _toast(restored == 0 ? '没有可回滚的内容' : '已撤销，$restored 条记录回到操作前');
  }
}

/// 右下角按钮列的统一规格。
///
/// 三颗按钮（[ScrollJumpButton] / [_QuickNoteButton] / [_NewRecordFab]）
/// 在右下角竖着叠成一列，**尺寸与圆角逐像素一致**才看起来是一组，
/// 所以边长和圆角在这里定义一次，[ScrollJumpButton] 用 `side` 参数取同一个值。
///
/// 三者语义上分两层：
/// - 主色底 = 主操作（[_NewRecordFab] 进编辑页写一条）；
/// - 卡片白底 = 辅助操作（[_QuickDock]：速记 / 计时 / 到顶到底）。
const double _buttonSide = 56;

/// 圆角 18 —— 与 [ScrollJumpButton] 的 `_shapeFor(56)` 是同一个值。
const BorderRadius _buttonShape = BorderRadius.all(Radius.circular(18));

/// 相邻两颗按钮之间的垂直间隙。
const double _buttonGap = 16;

/// 浮动操作的落位（距底部像素）。自下而上分两层：
/// **记一笔（FAB）→ 快捷胶囊（速记 / 计时）**。
///
/// FAB 默认边距 16；胶囊 dock 悬在 FAB 正上方（+ 边长 + 间隙）。
/// dock 内自上而下是 计时 / 速记 —— 速记贴着 FAB，是「写一条」的快捷路径。
/// 「到底」按钮独立：屏幕下缘居中、滑动时才出现（见 [_ToBottomButton]）。
const double _fabBottom = 16;
const double _dockBottom = _fabBottom + _buttonSide + _buttonGap; // 88
const double _toBottomBottom = 24;

/// dock 内每段的固定高（56）与分隔线粗细（1）。
/// 高度用固定值而不是 Expanded：dock 总高 = 段数×56 + (段数-1)×1，
/// 每段正好与 FAB 等大，几何关系可以被测试精确断言。
const double _dockSegmentHeight = 56;
const double _dockDividerHeight = 1;

/// 按「停靠边 + 底部偏移」摆一颗浮动按钮。
///
/// 左右停靠共用同一个 14 的屏幕边距（FAB 走 Scaffold 的 float 位置，
/// 默认边距 16，与这里是历史差异，视觉上无感）。
Positioned _floatPositioned({
  required ButtonSide side,
  required double bottom,
  required Widget child,
}) {
  return Positioned(
    left: side == ButtonSide.left ? 14 : null,
    right: side == ButtonSide.right ? 14 : null,
    bottom: bottom,
    child: child,
  );
}

/// 快捷胶囊 dock：计时 / 速记 两段收在一枚竖向胶囊里。
///
/// 2026-10-22 定稿形态：两段共用一个容器、一层投影，与独立主色的 FAB
/// 形成「一主一辅」的层次；宽度锁 56 与 FAB 等宽对齐，计时 MM:SS 用
/// FittedBox 等比缩小，绝不撑宽 dock。每段高 56 + 1px 分隔线，几何可测。
/// 「到底」不在此 dock（屏幕下缘居中，见 [_ToBottomButton]）；
/// 「到顶」由主页图标再点承担（回顶 + 刷新）。
class _QuickDock extends StatelessWidget {
  const _QuickDock({required this.showQuickNote});

  final bool showQuickNote;

  @override
  Widget build(BuildContext context) {
    final surfaces = VestigeSurfaces.of(context);
    final divider = Container(
      height: _dockDividerHeight,
      color: surfaces.border,
    );

    // 自上而下：计时 / 速记（速记贴着下面的 FAB）。
    final segmentCount = showQuickNote ? 2 : 1;
    final dividerCount = segmentCount - 1;

    return Material(
      color: surfaces.card,
      elevation: 3,
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: _buttonSide,
        height:
            segmentCount * _dockSegmentHeight +
            dividerCount * _dockDividerHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _TimerButton(),
            if (showQuickNote) ...<Widget>[divider, const _QuickNoteButton()],
          ],
        ),
      ),
    );
  }
}

/// 首页唯一的「记一笔」按钮：进编辑页写一条。
///
/// 「补记」不单独占入口 —— 新建和补记是同一件事，只是业务日期不同，
/// 进编辑页后在「今天 / 补交」里选。
///
/// **不支持长按速记**（2026-09-28 移除）：`FloatingActionButton` 内部的
/// InkWell 自带长按识别器，会把外层 GestureDetector 的长按挤掉（安卓端 100% 失效）。
/// 速记因此是并列的独立入口（[_QuickNoteButton]），在本按钮右边。
///
/// 形状是 56×56 正方形（圆角 18），与速记/计时三颗等大对齐；
/// 用普通 FAB 而不是 extended（胶囊宽随内容），只留「+」图标。
class _NewRecordFab extends ConsumerWidget {
  const _NewRecordFab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      // key 供测试量按钮整体框（FloatingActionButton 自身的 render box
      // 会受主题 tapTargetSize 影响，量它测不准外框）。
      key: const ValueKey('fab_button'),
      width: _buttonSide,
      height: _buttonSide,
      child: FloatingActionButton(
        heroTag: 'fab-record',
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 3.5,
        highlightElevation: 6,
        shape: const RoundedRectangleBorder(borderRadius: _buttonShape),
        tooltip: '记一笔',
        onPressed: () => context.push(AppRoutes.editNew()),
        child: const Icon(Icons.add_rounded, size: 24),
      ),
    );
  }
}

/// 「到底」按钮：屏幕下缘居中的临时胶囊，滑动列表时淡入、停手 1 秒收起。
///
/// 2026-10-22 重设计：原来的「到顶/到底」二合一按钮拆开了 ——
/// - 「到底」留在这里：往长列表深处翻时，一个明确直达末尾的出口；
/// - 「到顶」不再要按钮：主页图标再点即回顶（顺带刷新，见
///   [homeTopRequestProvider]）—— 底部导航本来就常驻在拇指边上，
///   比浮在列表上的按钮更顺手。
///
/// 可见性：距底部 12px 以内视为已在底部（隐藏）；其余滚动中显示，
/// 停手 [hideDelay] 后淡出。出现/消失只动透明度与 24px 位移，不参与布局。
class _ToBottomButton extends StatefulWidget {
  const _ToBottomButton({required this.controller});

  final ScrollController controller;

  @override
  State<_ToBottomButton> createState() => _ToBottomButtonState();
}

class _ToBottomButtonState extends State<_ToBottomButton> {
  static const Duration _hideDelay = Duration(seconds: 1);
  static const double _edgeThreshold = 12;

  Timer? _hideTimer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ToBottomButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final atBottom =
        position.pixels >= position.maxScrollExtent - _edgeThreshold;

    _hideTimer?.cancel();
    if (!atBottom) {
      _hideTimer = Timer(_hideDelay, () {
        if (mounted) setState(() => _visible = false);
      });
    }
    if (_visible == atBottom) {
      setState(() => _visible = !atBottom);
    }
  }

  Future<void> _go() async {
    if (!widget.controller.hasClients) return;
    await widget.controller.animateTo(
      widget.controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: VestigeMotion.fast,
        curve: VestigeMotion.curve,
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : const Offset(0, 0.4),
          duration: VestigeMotion.fast,
          curve: VestigeMotion.curve,
          child: Semantics(
            button: true,
            label: '跳到列表末尾',
            key: const ValueKey('to_bottom_button'),
            child: Material(
              color: surfaces.card,
              elevation: 3,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _go,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.vertical_align_bottom_rounded,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '到底',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「速记」段：不进编辑页，直接记一条内容为 [quickNoteContent] 的今日记录。
///
/// 为什么是独立入口而不是 FAB 的长按（2026-09-28）：
/// 长按方案在安卓端完全失效 —— `FloatingActionButton` 内部的 InkWell 自带长按识别器，
/// 与外包的 `GestureDetector.onLongPress` 在手势竞技场里冲突，外层回调不会触发。
/// `FloatingActionButton` 本身没有 `onLongPress` 参数，所以改成并列的独立入口。
///
/// 2026-10-22 定稿：它是 [_QuickDock] 的最下段（贴着 FAB），
/// 容器（白底胶囊、投影、圆角）由 dock 统一提供，这里只负责交互与内容。
class _QuickNoteButton extends ConsumerWidget {
  const _QuickNoteButton();

  /// 速记写入的正文。
  ///
  /// 不用 `quickAddToday` 的缺省 `1`（那是原 App「敲一下就是一次」的计数语义），
  /// 这里显式传值，语义是「先占个位、回头再补内容」。
  static const String quickNoteContent = '速记';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: '速记：直接记一条今天的',
      // key 供测试量按钮整体框（按图标找只会量到 24px 的图标本身）。
      key: const ValueKey('quick_note_button'),
      child: SizedBox(
        height: _dockSegmentHeight,
        child: InkWell(
          onTap: () => _quickAdd(context, ref),
          child: Center(
            child: Icon(Icons.bolt_rounded, size: 24, color: scheme.primary),
          ),
        ),
      ),
    );
  }

  /// 直接记一条今天的记录，并给一次撤销机会。
  Future<void> _quickAdd(BuildContext context, WidgetRef ref) async {
    // 记住**这一条**的 id（2026-10-27 审查 C-003）：原先是撤销时反查
    // 「业务日期=今天 且 createdAt 最大」的那条，插入还没回流、或当天另存过记录时
    // 会删掉别的记录。id 是插入前就确定的，撤销因此不再需要推断。
    final id = await ref
        .read(recordActionsProvider)
        .quickAddToday(content: quickNoteContent);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // 撤销类提示统一带主色撤销图标（与 _toastUndoable 同一套分级）。
          content: Row(
            children: <Widget>[
              Icon(
                Icons.undo_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(child: Text('已速记一条（今天）')),
            ],
          ),
          // 与 _toastUndoable 同一档：带撤销按钮的提示都要
          // ① 显式 persist: false（否则永不消失）② 时长 3 秒。
          duration: const Duration(seconds: 3),
          persist: false,
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoQuickAdd(ref, id),
          ),
        ),
      );
  }

  /// 撤销刚插入的那一条（按 id 精确软删）。
  Future<void> _undoQuickAdd(WidgetRef ref, String id) async {
    await ref.read(recordActionsProvider).deleteRecord(id);
  }
}

/// 「计时」按钮：开始/结束一次计时，结束时带着时长进编辑页。
///
/// - 未计时：显示表盘图标，点击开始；
/// - 计时中：显示 `MM:SS` 钟面（每秒走一格），点击弹「停止并记录 / 放弃」；
///   停止并记录 → 结算分钟数（向上取整）→ 跳编辑页预填时长。
///
/// 钟面的秒级刷新用本地 1s Timer 而不是全局 ticker：只有这一颗按钮在动，
/// 不拖累整页重建。计时开始时刻持久化在 SharedPreferences（见
/// [DurationTimerNotifier]），杀进程重开计时照走。
class _TimerButton extends ConsumerStatefulWidget {
  const _TimerButton();

  @override
  ConsumerState<_TimerButton> createState() => _TimerButtonState();
}

class _TimerButtonState extends ConsumerState<_TimerButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 首次对齐放在 initState，而不是 build（2026-10-27 审查 m-008）：
    // build 是幂等的渲染函数，在里面创建/取消 Timer 属于副作用，一旦哪天
    // build 被更频繁地调用（例如主题变化），ticker 会被反复重开。
    _syncTicker(ref.read(durationTimerProvider) != null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 计时状态变化时对齐秒级 tick 的生命周期（开始 → 建；结束/放弃 → 撤）。
  void _syncTicker(bool running) {
    if (running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _onTap() async {
    final notifier = ref.read(durationTimerProvider.notifier);
    if (ref.read(durationTimerProvider) == null) {
      await notifier.start();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('计时开始，做完再点这个按钮结束'),
            duration: Duration(seconds: 3),
            persist: false,
          ),
        );
      return;
    }

    final startedAt = ref.read(durationTimerProvider)!;
    final choice = await showVestigeCenterDialog<bool>(
      context: context,
      builder: (context) => _TimerStopDialog(startedAt: startedAt),
    );
    if (choice == null || !mounted) return;

    if (!choice) {
      // 放弃：不结算
      await notifier.cancel();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已放弃本次计时'),
            duration: Duration(seconds: 3),
            persist: false,
          ),
        );
      return;
    }

    // 停止并记录：结算秒数，带着它进编辑页
    final seconds = await notifier.stop();
    if (!mounted) return;
    // 收尾确认触觉：这一下代表「一件事完成了」。
    HapticFeedback.selectionClick();
    context.push(AppRoutes.editNew(durationSec: seconds));
  }

  @override
  Widget build(BuildContext context) {
    // 计时开/停（含从别的页面回来、被放弃）都走这里对齐 ticker。
    ref.listen<DateTime?>(durationTimerProvider, (_, next) {
      _syncTicker(next != null);
    });
    final startedAt = ref.watch(durationTimerProvider);
    final running = startedAt != null;

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      label: running ? '停止计时并记录' : '开始计时',
      key: const ValueKey('timer_button'),
      child: SizedBox(
        height: _dockSegmentHeight,
        child: InkWell(
          onTap: _onTap,
          child: Center(
            child: running
                // 钟面每秒换一个 key，AnimatedSwitcher 做 120ms 级的轻微
                // 淡入 —— 配合 tabular figures，观感从「电子表」变「表盘」。
                ? AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    switchInCurve: VestigeMotion.curve,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        elapsedClockLabel(
                          DateTime.now().difference(startedAt).inSeconds,
                        ),
                        key: ValueKey<String>(
                          elapsedClockLabel(
                            DateTime.now().difference(startedAt).inSeconds,
                          ),
                        ),
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                  )
                : Icon(
                    Icons.timelapse_outlined,
                    size: 24,
                    color: scheme.primary,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 计时中的确认弹层：显示已经走了多久，让用户选「停止并记录」还是「放弃」。
///
/// 秒数在这里**就地展示结算预览**，用户按下去之前就知道这条会被记成多久，
/// 不用跳到编辑页再发现「怎么是 1 秒」。
class _TimerStopDialog extends StatelessWidget {
  const _TimerStopDialog({required this.startedAt});

  final DateTime startedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = DateTime.now().difference(startedAt);
    final seconds = elapsed.inSeconds < 1 ? 1 : elapsed.inSeconds;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '计时中 · ${elapsedClockLabel(elapsed.inSeconds)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '这条将记为 ${durationLabel(seconds)}。不做完也可以先记一半 ——'
            '时长之后在编辑页还能改。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              TextButton(
                // false = 放弃
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('放弃计时'),
              ),
              const Spacer(),
              FilledButton.icon(
                // true = 停止并记录
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('停止并记录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 主页标题：第一行是「今天是哪天」，第二行是「距离上次记录多久」。
///
/// 为什么拆两行：单行写成「2026年9月17日 周四 · 距上次记录 3 天」在 360 宽的机器上
/// 会被 AppBar 挤断（标题区可用宽约 290，这串 26 个字符约 340）。拆开之后两行都宽松，
/// 而且「日期」和「间隔」本来就是两种信息：一个是锚点，一个是提醒。
class _HomeTitle extends StatelessWidget {
  const _HomeTitle({required this.date, required this.gapDays});

  final String date;

  /// 今天 − 最近一次有记录的那天；null = 还没有任何记录。
  final int? gapDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 今天已经记过了（gapDays 为 null 表示一条都没有，不算）
    final recordedToday = gapDays != null && gapDays! <= 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          date,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (recordedToday)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            Text(
              lastRecordGapLabel(gapDays),
              // 「今天已记录」用主色、其余用弱色：这是首页唯一一句「状态」，
              // 今天已经记过的时候值得给一点正向反馈。
              style: theme.textTheme.labelSmall?.copyWith(
                color: recordedToday ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: recordedToday ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.group, required this.todayNumber});

  final RecordGroup group;

  /// 「今天是哪天」的 [dayNumber]，由父级统一传入（见 HomeScreen.build）。
  final int todayNumber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);

    // 左右/上下留白由外层行负责（见 home_screen 的 itemBuilder），
    // 这里只出内容 —— 行高是外面声明好的，多一层 Padding 就会顶破它。
    return Row(
      spacing: 8,
      children: <Widget>[
        // 主色小竖条：给「这是新的一天」一个不必读字就能看懂的锚点。
        // 高度锁在 14px 一行文字内，不参与行高计算。
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Text(
          groupHeaderLabelOf(group.dayNumber, todayNumber: todayNumber),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        Text(
          '${group.count} 条',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (group.backfilledCount > 0)
          Text(
            '补记 ${group.backfilledCount}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.backfill,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

/// 标签筛选弹层（模态底部弹层，与统计页的年份弹层同一套语言：
/// 抓手条 + 标题 + 列表行）。
///
/// 为什么从「主页上一排横滑 chip」改成弹层：
/// - 那排 chip 是 `SliverPersistentHeader(pinned)`，**常驻 48px**，标签一多还得横滑着找，
///   为了一件低频操作永久吃掉列表首屏；
/// - 标签是全站共享的维度，塞进弹层后每行能排得下「#标签」+ 条数 + 勾选，
///   信息密度反而更高（原来窄 chip 里数字只能缩成小字）。
///
/// **复选**（2026-09-22 二改）：每行左侧是方形复选框而不是单选勾 ——
/// 勾第二个标签**不会**把第一个挤掉。多选的语义是「或」（见 `homeRowsProvider`），
/// 所以勾了几个就是「这几个标签的记录一起看」，每次勾选**列表立刻变**，
/// 用户能在弹层开着的时候盯着背后那份列表收敛。
///
/// 交互：点一行 = 勾上/取消；点遮罩/抓手 = 直接关掉，
/// **不 pop 传值** —— 页面读的是 [selectedTagsProvider]，弹层只负责写它。
class _TagSheet extends ConsumerWidget {
  const _TagSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = ref.watch(tagCountsProvider);
    final selected = ref.watch(effectiveTagFilterProvider);
    // 「全部 N」上的 N 用总条数：它是「不筛选」那一档，对应的是全部记录。
    final total = ref.watch(recordStatsProvider).totalCount;

    return ConstrainedBox(
      // 最多占八成屏高，超出让列表自己滚（2 个标签时它就是个紧凑的小弹层）
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
                // 标题前放一个**三态全选框**：原先是纯文字标题，现在它同时是
                // 「全选/全不选」的开关 —— 复选列表里这个位置本来就是全选位的习惯落点。
                // 三态语义（全选/部分/全不选）由 `tristate` + `value: null` 表达，
                // 不用自己判断「有没有部分选中」。
                // 这里必须有自己的 Checkbox（而不是复用「全部」药丸）：
                // 那个药丸是「清除筛选」，与「把候选集全勾上」是两件相反的事。
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    tristate: true,
                    // null = 部分选中（勾了至少一个但没全勾）
                    value: selected.isEmpty
                        ? false
                        : selected.length == tags.length
                        ? true
                        : null,
                    // **不用回调给的 v 来判断要做什么**：tristate 下 `onChanged` 传的是
                    // 循环下一个值（false → true → null → false…），
                    // 所以在「部分选中」(null) 时点一下拿到的是 `false`，
                    // 照它走会变成「清空」——而用户的本意是「补齐成全选」。
                    // 按**当前状态**决定：已全选才清空，其余（全不选 / 部分）一律全选。
                    onChanged: (_) {
                      final ctrl = ref.read(selectedTagsProvider.notifier);
                      if (selected.length == tags.length &&
                          selected.isNotEmpty) {
                        ctrl.clear();
                      } else {
                        ctrl.selectAll(tags.map((t) => t.tag));
                      }
                    },
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '按标签筛选',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                // 勾了几个就直接写在标题边上 —— 复选状态下「我到底勾了哪些」
                // 得翻列表数勾选框，是个不该让用户做的事。
                if (selected.isNotEmpty)
                  Text(
                    '已选 ${selected.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(),
                // 右侧「全部 N」= 清除筛选。它和其余标签是同一件事的两种选择，
                // 摆在标题栏比在列表里插一个「全部」行更省位置，而且列表滑到底也够得着。
                _AllFilterChip(
                  selected: selected.isEmpty,
                  count: total,
                  onTap: () => ref.read(selectedTagsProvider.notifier).clear(),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              children: <Widget>[
                for (final t in tags)
                  _tile(context, ref, t.tag, t.count, selected.contains(t.tag)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    WidgetRef ref,
    String tag,
    int count,
    bool isSelected,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return ListTile(
      // 不用 dense：弹层行要的是「按得中、看得清」，标准 56 高 + 标准字号
      // 才摊得开；dense 会让整框显得狭窄局促（2026-10-22 用户反馈）。
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      visualDensity: const VisualDensity(horizontal: 0, vertical: 2),
      selected: isSelected,
      // 实色高亮：弹层底色是容器白，半透明的浅蓝叠上去几乎看不出选中（与年份弹层同理）。
      selectedTileColor: scheme.primaryContainer,
      // 复选框放**行首**而不是行尾：复选列表的勾选位在左边才符合系统习惯
      // （多选列表都是这样），行尾留给「N 条」这一列数字。
      leading: SizedBox(
        width: 24,
        height: 24,
        // 用 Material 自己的 Checkbox：复选语义、禁用态、焦点框、无障碍
        // （Semantics `checked` / `inMutuallyExclusiveGroup=false`）全都自带，
        // 手画一个方形勾选框只能拿到外观，拿不到这些。
        child: Checkbox(
          value: isSelected,
          onChanged: (_) => ref.read(selectedTagsProvider.notifier).toggle(tag),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: BorderSide(color: surfaces.border, width: 1.5),
        ),
      ),
      title: Text(
        '#$tag',
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          color: isSelected ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
      ),
      // 「N 条」每行都占着固定位置（这里不需要再留勾选位了，勾选框在行首）。
      trailing: Text(
        '$count 条',
        style: theme.textTheme.labelMedium?.copyWith(
          color: isSelected
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      // 整行可点（不只是那个 24px 的方块）：复选列表里点一半行没反应最恼人。
      onTap: () => ref.read(selectedTagsProvider.notifier).toggle(tag),
    );
  }
}

/// 弹层标题栏右侧的「全部 N 条」小药丸 —— 当前无筛选时是选中态。
class _AllFilterChip extends StatelessWidget {
  const _AllFilterChip({
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Material(
      color: selected ? scheme.primaryContainer : surfaces.inset,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.pillAll,
        side: BorderSide(color: selected ? scheme.primary : surfaces.border),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            '全部 $count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 筛选生效时列表顶端那行细指示条。
///
/// 它不是「栏」（不吸顶、不占固定高度）：筛选是个临时视角，
/// 用户随时可能清除，所以让它**跟着列表滚走**，而不是永久钉在 AppBar 下面。
///
/// 布局（2026-09-22 复选改版）：一行放不下所有勾中的标签 —— 勾到第 6 个时
/// 「只看 #a #b #c #d #e #f · 23 条」早就把「清除筛选」挤出去了。
/// 所以标签本身排成**可横滑的一列 chip**，每个 chip 上带 ×（单独的取消入口，
/// 不用回弹层），末尾固定跟着条数与「清除筛选」。
class _ActiveTagBanner extends StatelessWidget {
  const _ActiveTagBanner({
    required this.tags,
    required this.count,
    required this.onClear,
    required this.onRemove,
  });

  final Set<String> tags;
  final int count;
  final VoidCallback onClear;

  /// 点某个 chip 上的 × = 只取消这一个标签。
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 勾选顺序在 Set 里没有保证，这里按名称排一下让 chip 次序稳定 ——
    // 否则同一个筛选状态在两次构建之间 chip 会换位，看着像闪。
    final sorted = tags.toList()..sort();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Row(
        children: <Widget>[
          Icon(Icons.sell_rounded, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          // 标签区横滑：勾得再多也只是一条 32 高的小行，不会把指示条撑成两排。
          Flexible(
            child: SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                shrinkWrap: true,
                itemCount: sorted.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) => _RemovableChip(
                  tag: sorted[index],
                  onRemove: () => onRemove(sorted[index]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count 条',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
          // 用 TextButton 而不是 IconButton：这里需要「清除筛选」四个字，
          // 一个 × 在中文界面里容易被读成「关闭这一条通知」。
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('清除筛选'),
          ),
        ],
      ),
    );
  }
}

/// 指示条上的一个标签 chip：`#标签` + 一个小 ×。
class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.tag, required this.onRemove});

  final String tag;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Material(
      color: surfaces.inset,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.pillAll,
        side: BorderSide(color: surfaces.border),
      ),
      child: InkWell(
        // 整块 chip 就是「去掉这个标签」—— 32 高的小药丸里再塞一个独立的
        // 点击区（20px 的 ×）手指根本点不准，不如让它整体可点。
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '#$tag',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.close_rounded, size: 13, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);

    return Padding(
      // 底部多留出右下角 FAB 的高度，文案不会被按钮压住
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 104),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          // 图标坐进主色圆盘里：双层光环与轻阴影
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.18),
                width: 2,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.10),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              Icons.pets_rounded,
              size: 40,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '还没有任何记录',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点右下角「+」写下第一条；\n忘了记的那几天，进编辑页把日期改成那一天就行。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: surfaces.card,
              borderRadius: VestigeRadius.mediumAll,
              border: Border.all(color: surfaces.border, width: 0.8),
              boxShadow: surfaces.cardShadow,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.lightbulb_outline_rounded,
                    size: 18,
                    color: tokens.backfill,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // 文案必须指向**现在真实存在**的入口（2026-10-27 审查 m-001）：
                    // 「长按 + 」那个手势 2026-09-28 已随 FAB 长按方案一起移除，
                    // 原文案会让用户对着按钮长按、然后以为功能坏了。
                    '长按卡片可多选、整体调整日期；'
                    '点 FAB 上方的闪电图标 = 立刻记一条今天的。',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
