/// 一次撤销的实际效果。
///
/// 撤销在两个方向上改变数据，条数必须分开算：
/// - [restored]：按「操作前快照」整行写回的记录数（覆盖、回滚标签、救回删除）；
/// - [removed]：按「本次新插入」名单**彻底删除**的记录数（撤回 CSV 导入的新增，
///   见 `UndoEntries.insertedIds`）。
///
/// 只报一个合计会让导入的撤销说不清 —— 「已撤销，120 条记录回到操作前」在
/// 「100 条新增被删掉」的场景里是错的描述。
///
/// 文案放这里而不是各页面各写一套：撤销提示有三处（首页、回收站、操作历史），
/// 分开写必然走偏。
class UndoOutcome {
  const UndoOutcome({this.restored = 0, this.removed = 0});

  /// 没有改动任何记录。
  static const UndoOutcome none = UndoOutcome();

  /// 整行写回的条数。
  final int restored;

  /// 被彻底删除的条数。
  final int removed;

  /// 合计影响的条数（判空用）。
  int get total => restored + removed;

  /// 给用户看的一句话结论。
  String get message {
    if (total == 0) return '没有可回滚的内容';
    if (removed == 0) return '已撤销，$restored 条记录回到操作前';
    if (restored == 0) return '已撤销，删除了本次新增的 $removed 条记录';
    return '已撤销，还原 $restored 条、删除新增的 $removed 条';
  }
}
