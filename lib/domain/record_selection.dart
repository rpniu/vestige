import 'dart:collection';

/// 记录多选态的**共享状态**：首页和回收站共用这一份，不再各写一遍。
///
/// 为什么要抽出来：这两个页面的多选本来就是同一套交互 —— 三态全选框、
/// 逐条勾选、一个显式出口、批量操作完自动收掉。但原先各自写了一份实现，
/// 改一处忘一处就会跑偏。2026-09-23 那个「取消全选直接退出多选」的 bug
/// 就是典型：首页改对了，回收站还得记得再改一次。
///
/// 放在 `domain/` 而不是 `presentation/`：它**刻意不依赖 Flutter**
/// （没有 ChangeNotifier、不碰 setState），只是个装状态的普通对象，
/// 由持有它的 `State` 在改动后自己调 `setState`。这样这份逻辑能直接单测，
/// 不用起 widget —— 和 [CsvUtil]、[DayUtil] 是同一类东西。
class RecordSelection {
  final Set<String> _ids = <String>{};
  bool _active = false;

  /// 多选态是不是开着。
  ///
  /// **显式开关，不由「勾选是否非空」推导** —— 否则「取消全选」把勾选清空时，
  /// 多选态会被连带关掉：用户只是想清掉勾选、重新挑几条，却得重新长按一次。
  /// 所以「已选 0 条」是个合法中间状态（标题照常显示、批量按钮置灰）。
  bool get isActive => _active;

  /// 已勾选的记录数。
  int get count => _ids.length;

  bool get isEmpty => _ids.isEmpty;

  bool get isNotEmpty => _ids.isNotEmpty;

  /// 已勾选的 id（只读视图，外部改不动内部集合）。
  Set<String> get ids => UnmodifiableSetView(_ids);

  /// 已勾选 id 的快照 —— 批量操作前取一份，避免操作途中集合被改。
  List<String> snapshot() => _ids.toList(growable: false);

  /// 某条记录是否被勾选。
  bool contains(String id) => _ids.contains(id);

  /// 三态全选框的值：`false` = 全不选，`true` = 全选，`null` = 部分选中。
  ///
  /// 判据是「候选集里的每一条都被勾上了」，**不是**「勾选数 ≥ 候选数」。
  /// 后者在勾选集里混进了候选之外的 id 时会误判成「已全选」，
  /// 于是点下去走的是「全选」分支而不是「清空」，用户感受就是「点了没反应」。
  bool? triStateOf(Iterable<String> candidates) {
    if (_ids.isEmpty) return false;
    return coversAll(candidates) ? true : null;
  }

  /// 候选集是不是**全部**都被勾上了。
  ///
  /// 空候选集返回 false：没有可勾的东西，谈不上「全选」。
  bool coversAll(Iterable<String> candidates) {
    var n = 0;
    for (final id in candidates) {
      if (!_ids.contains(id)) return false;
      n++;
    }
    return n > 0;
  }

  /// 勾选 / 取消勾选一条（首页长按卡片、回收站点卡片都走这里）。
  ///
  /// 只开不关：取消勾选最后一条也**不会**退出多选态。
  /// 否则「取消全选」和「手动取消最后一条」会走出两种不同结果，
  /// 而它们对用户来说是同一个动作 —— 把勾选清掉。
  void toggle(String id) {
    _active = true;
    if (!_ids.remove(id)) _ids.add(id);
  }

  /// 全选 / 全不选（三态全选框来回切，AppBar 上只占一个位置）。
  ///
  /// 「全不选」只清勾选，**不关多选态** —— 用户点它是想把当前这批清掉重新挑，
  /// 不是想退出多选。要退出请走 [exit]。
  ///
  /// 清空用 [Set.clear] 而不是 `removeAll(candidates)`：勾选集本来就被
  /// [prune] 约束成候选集的子集，两者等价；但万一将来约束松了，
  /// `clear()` 至少能保证勾选框一定回落到「全不选」，不会卡在「已勾选」上。
  void toggleAll(Iterable<String> candidates) {
    _active = true;
    if (coversAll(candidates)) {
      _ids.clear();
    } else {
      _ids.addAll(candidates);
    }
  }

  /// 退出多选态（显式出口）：关开关 + 清勾选，两件事必须一起做。
  ///
  /// 批量操作（删除 / 平移日期 / 恢复）执行完也走这里 ——
  /// 操作做完了，多选态就没有存在意义，顺势收掉。
  void exit() {
    _active = false;
    _ids.clear();
  }

  /// 勾选集里有没有**已经失效的**项（[prune] 的只读预检）。
  ///
  /// 单独拆出来是为了让调用方能在 `build` 里安全地判断：`build` 期间不该改状态
  /// （哪怕改了不会触发重建），所以预检在 `build` 里做、真正的清理扔到 post-frame。
  bool hasStale(Iterable<String> stillValid) {
    if (_ids.isEmpty) return false;
    final valid = stillValid is Set<String> ? stillValid : stillValid.toSet();
    return !_ids.every(valid.contains);
  }

  /// 丢掉**已经不存在的**勾选项：记录被删除、被恢复，或者被标签筛掉了。
  ///
  /// 为什么必须剪枝：批量操作是不可逆的，勾选集里留着一个屏幕上根本看不见的 id，
  /// 就意味着「移入回收站」会删掉用户没看见的记录 —— 这是事故，不是小瑕疵。
  /// 首页的候选集本来就定义为「当前可见的这些」，所以「被筛掉」也算失效。
  ///
  /// **只清勾选，不动 [isActive]**：哪怕清到一条不剩，多选态也留着 ——
  /// 退出由用户自己决定（点「取消选择」或按返回），不应代为退出。
  ///
  /// 返回是否真的丢掉了东西 —— 调用方据此决定要不要 `setState`，
  /// 避免每帧都触发一次无意义的重建。
  bool prune(Iterable<String> stillValid) {
    if (_ids.isEmpty) return false;
    final valid = stillValid is Set<String> ? stillValid : stillValid.toSet();
    final before = _ids.length;
    _ids.removeWhere((id) => !valid.contains(id));
    return _ids.length != before;
  }
}
