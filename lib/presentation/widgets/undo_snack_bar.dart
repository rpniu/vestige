import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vestige/domain/undo_outcome.dart';

/// 显示一条带「撤销」的提示条。
///
/// 三处硬性约束集中在这里，避免每加一个可撤销入口就复制一遍：
/// 1. **`persist: false` 必须显式给出** —— `SnackBar.persist` 的默认值是
///    `action != null`，带按钮的提示条默认**永不自动消失**，下面那 3 秒会被
///    完全忽略（见 material/snack_bar.dart 里 persist 的文档）；
/// 2. 时长 3 秒：够看清、够反应过来，又不占着屏幕。敢这么短是因为有兜底 ——
///    撤销历史保留最近 20 步且不过期，错过窗口还有「操作历史」；
/// 3. 撤销目标是**这次操作刚写下的那条历史**（`lastUndoEntryId`），
///    不是「历史里最新的一步」：两者在「这次操作没产生回退点」时会分歧，
///    退最新一步会退掉上一个不相关的操作（2026-10-27 审查 M-007）。
///    所以 [entryId] 为 null 时**不挂按钮**，退化成普通提示。
///
/// [onUndo] 返回撤销结果，提示条据此报一句结论（「还原 N 条」「删除 N 条新增」，
/// 文案在 `UndoOutcome.message`）。
void showUndoableSnackBar(
  ScaffoldMessengerState messenger, {
  required Color accent,
  required String message,
  required int? entryId,
  required Future<UndoOutcome> Function(int entryId) onUndo,
}) {
  messenger.hideCurrentSnackBar();
  if (entryId == null) {
    // 没有可回退的条目：照常提示，但不给一个点了会退错东西的按钮。
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      // 撤销类提示统一带主色撤销图标：与普通 toast 在视觉上分级。
      //（本版 SnackBar 没有 icon 参数，图标并进 content 行首。）
      content: Row(
        children: <Widget>[
          Icon(Icons.undo_rounded, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
      duration: const Duration(seconds: 3),
      persist: false,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () {
          // 回调是 VoidCallback：异步链不能挂在 onPressed 上等它，
          // 失败也不该让提示条卡住，所以显式 unawaited。
          unawaited(() async {
            final outcome = await onUndo(entryId);
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(outcome.message)));
          }());
        },
      ),
    ),
  );
}

/// [showUndoableSnackBar] 的页面级入口：自己取 messenger 与主色。
///
/// 页面**仍在树上**时用它；若要在 `pop` 之后显示（编辑页保存完就退回上一页），
/// 必须提前 `ScaffoldMessenger.of(context)` 拿住 messenger，改用上面那个版本 ——
/// pop 之后再读 `context` 已经失效。
void showUndoableSnackBarOf(
  BuildContext context, {
  required String message,
  required int? entryId,
  required Future<UndoOutcome> Function(int entryId) onUndo,
}) =>
    showUndoableSnackBar(
      ScaffoldMessenger.of(context),
      accent: Theme.of(context).colorScheme.primary,
      message: message,
      entryId: entryId,
      onUndo: onUndo,
    );
