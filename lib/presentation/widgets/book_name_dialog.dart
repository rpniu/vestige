import 'package:flutter/material.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/record_book.dart';

/// 新建 / 重命名记录本共用的取名弹层。
///
/// 抽成公共组件是因为有两个入口都要它：记录本管理页（新建 + 改名）
/// 与首页的快捷切换弹层（只新建）。文案与校验只写一份，
/// 两个入口的名字规则才不会分叉。
///
/// 返回 pop 出来的**已规范化**名字（[normalizeBookName] 之后），取消返回 null。
/// 校验放在这里而不是调用方：空名字的「确定」按钮必须是灰的，
/// 否则用户点了没反应还不知道为什么。
class BookNameDialog extends StatefulWidget {
  const BookNameDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.initialName,
  });

  final String title;
  final String confirmLabel;

  /// 改名时预填的现有名字；新建时为空。
  final String? initialName;

  @override
  State<BookNameDialog> createState() => _BookNameDialogState();
}

class _BookNameDialogState extends State<BookNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = normalizeBookName(_controller.text);
    if (name == null) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: kMaxBookNameLength,
        textInputAction: TextInputAction.done,
        // 回车即确认：取名是一步操作，没必要强制去点按钮。
        onSubmitted: (_) => _submit(),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          hintText: '例如：工作 / 读书 / 旅行',
          counterText: '',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: normalizeBookName(_controller.text) == null
              ? null
              : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 新建记录本之后该给用户说什么。
///
/// 两个入口（管理页 / 快捷切换弹层）共用一份文案：**新建不自动切过去**，
/// 所以提示里必须点名「点它即可切换」，否则用户会以为新建失败了。
String createdBookToast(RecordBookEntity? book) => book == null
    ? '已有同名记录本，或名字不可用'
    : '已新建「${book.name}」，点它即可切换';
