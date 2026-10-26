import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

/// 批量打标签弹层的结果：要加哪些、要去掉哪些（两者互斥，只会有一边非空）。
typedef BatchTagResult = ({List<String> add, List<String> remove});

/// 批量打标签的弹层。
///
/// 交互：把**所有已存在的标签**列成可多选的 chip，下面再给一个输入框补一个新标签，
/// 最后两个按钮 ——「去掉这些」/「加上这些」。
///
/// 为什么不是单个「确定」：多选场景下用户的意图正好是相反的两件事 ——
/// 「这几条都归到 #旅行」和「这几条别再挂 #待办 了」。一个「确定」表达不了方向，
/// 只能让用户自己点明。
///
/// 返回值：[BatchTagResult]；用户点遮罩 / 按返回直接关掉则返回 null，
/// 调用方据此什么都不做（不能把「关掉弹层」当成「确认」）。
class BatchTagSheet extends ConsumerStatefulWidget {
  const BatchTagSheet({super.key, required this.count});

  /// 选中的记录条数，只用于标题文案。
  final int count;

  @override
  ConsumerState<BatchTagSheet> createState() => _BatchTagSheetState();
}

class _BatchTagSheetState extends ConsumerState<BatchTagSheet> {
  final Set<String> _picked = <String>{};
  final TextEditingController _newTag = TextEditingController();

  /// 标签较多时 chip 区内部滚动，避免撑破弹层（与标签筛选弹层同一处理）。
  static const double _maxChipAreaHeight = 240;

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  void _toggle(String tag) => setState(() {
        if (!_picked.remove(tag)) _picked.add(tag);
      });

  /// 输入框里的新标签；空串表示没填。前导 `#` 去掉，与编辑页的存法一致。
  String get _typedTag =>
      _newTag.text.trim().replaceFirst(RegExp(r'^#+'), '').trim();

  bool get _canAct => _picked.isNotEmpty || _typedTag.isNotEmpty;

  void _done({required bool adding}) {
    // 「加上」时把输入框那个新标签一起带上；「去掉」只认已存在的 chip ——
    // 一个还不存在的标签没什么可去掉的。
    final tags = <String>{
      ..._picked,
      if (adding && _typedTag.isNotEmpty) _typedTag,
    }.toList(growable: false);

    Navigator.of(context).pop(
      adding
          ? (add: tags, remove: const <String>[])
          : (add: const <String>[], remove: tags),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = ref.watch(tagCountsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '给选中的 ${widget.count} 条打标签',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '选好标签，再点下面的按钮决定是「加上」还是「去掉」。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (tags.isNotEmpty) ...<Widget>[
              ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: _maxChipAreaHeight),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: <Widget>[
                      for (final t in tags)
                        FilterChip(
                          label: Text('#${t.tag}'),
                          selected: _picked.contains(t.tag),
                          onSelected: (_) => _toggle(t.tag),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _newTag,
              // 输入变化 → 按钮可用态跟着变（「只填新标签、不勾 chip」也要能点）
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canAct) _done(adding: true);
              },
              decoration: const InputDecoration(
                labelText: '新标签（可选）',
                hintText: '例如：旅行',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _picked.isEmpty ? null : () => _done(adding: false),
                    icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                    label: const Text('去掉这些'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _canAct ? () => _done(adding: true) : null,
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                    label: const Text('加上这些'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
