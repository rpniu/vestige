import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/record_book_provider.dart';
import 'package:vestige/presentation/widgets/book_name_dialog.dart';
import 'package:vestige/presentation/widgets/error_state.dart';

/// 快捷切换记录本的弹层（首页 AppBar 那个图标点开的就是它）。
///
/// 与「记录本管理页」（`/books`，整页）的分工：
/// - **这里只管切换**：一眼看完、点一下就走。切换是高频小动作，
///   为它跳一次整页再返回等于每次多两步；
/// - 管理（新建 / 改名 / 删除）仍在整页里 —— 那些低频且需要确认，
///   塞进弹层会让「点错一下」的代价变高。标题行右侧给一个入口过去。
///
/// 弹层自己完成切换并关闭，调用方（首页）不需要处理返回值；
/// 唯一的外部动作是「去管理」，用 [onManage] 交回给页面（导航归页面管）。
///
/// 底部固定一个「新建记录本」：首页入口的语义就是「想换一本记」，
/// 而「还没有第二本」恰恰是最常见的起点 —— 让新建也走「+ → 取名」两步，
/// 而不是「+ → 管理 → 整页 → 新建」四步。
class BookSwitchSheet extends ConsumerWidget {
  const BookSwitchSheet({super.key, required this.onManage});

  /// 用户点了「管理」时调用（弹层已经先把自己关掉）。
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(recordBooksProvider);
    final activeId = ref.watch(activeBookIdProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _TitleRow(
          onManage: () {
            Navigator.of(context).pop();
            onManage();
          },
        ),
        // Flexible（不是 Expanded）：Column 是 min 高度，Expanded 的 tight 约束
        // 在无界高度下会抛错；Flexible 让列表在弹层最大高度内自己滚。
        Flexible(
          child: booksAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            ),
            // 先判 error 再判 data：出错时 data 同为 null，落到「空列表」
            // 会让用户以为记录本都没了。
            error: (error, _) => VestigeErrorState(
              error: error,
              onRetry: () => ref.invalidate(recordBooksProvider),
            ),
            data: (books) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              children: <Widget>[
                for (final book in books)
                  _BookTile(
                    book: book,
                    isActive: book.id == activeId,
                    onTap: () => _switchTo(context, ref, book),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 0),
        _CreateRow(onTap: () => _create(context, ref)),
      ],
    );
  }

  /// 新建记录本（不关弹层）。
  ///
  /// 建完**不自动切过去**（与记录本管理页同一条规则）：突然换本会让首页
  /// 变成一片空白，像数据丢了。新本会立刻出现在上面的列表里，点一下即可切。
  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const BookNameDialog(
        title: '新建记录本',
        confirmLabel: '新建',
      ),
    );
    if (name == null || !context.mounted) return;

    final book = await ref.read(recordBooksControllerProvider).create(name);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(createdBookToast(book))));
  }

  Future<void> _switchTo(
    BuildContext context,
    WidgetRef ref,
    RecordBookEntity book,
  ) async {
    final switched =
        await ref.read(recordBooksControllerProvider).switchTo(book.id);
    if (!context.mounted) return;
    // 切换后立刻关掉弹层：用户要看的下一屏就是新记录本的内容，
    // 停在一个已经过时的选择列表上没有意义。
    // 显式指定 rootNavigator：`showDialog` 默认把弹层推在根导航器上，
    // 关它也必须显式指向根，否则在带嵌套导航器（tab shell）的场景里会关错层。
    Navigator.of(context, rootNavigator: true).pop();
    if (!switched) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已切换到「${book.name}」')));
  }
}

/// 标题行：左标题 + 右侧「管理」入口（与全站弹层的标题行同构）。
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: <Widget>[
          // 主色竖条：与首页日期分组头、「我的」分节标题同一套分节语言
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '切换记录本',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          TextButton(onPressed: onManage, child: const Text('管理')),
        ],
      ),
    );
  }
}

/// 底部的「新建记录本」行。
///
/// 与上面的记录本行同一套行语言，但用主色 + 加号区分「这是一条动作，
/// 不是一个可选的本」—— 混在列表里会被误读成某一本记录本。
class _CreateRow extends StatelessWidget {
  const _CreateRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Row(
          children: <Widget>[
            Icon(Icons.add_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Text(
              '新建记录本',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行记录本：左图标方块、中间名字、右侧当前标记。
class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.isActive,
    required this.onTap,
  });

  final RecordBookEntity book;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Semantics(
      button: true,
      selected: isActive,
      child: InkWell(
        // 当前这本点了没意义：不给点击反馈，靠主色 + 勾说明它的地位。
        onTap: isActive ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isActive ? scheme.primaryContainer : surfaces.inset,
                  borderRadius: VestigeRadius.insetAll,
                  border: Border.all(color: surfaces.border, width: 0.6),
                ),
                child: Icon(
                  Icons.auto_stories_rounded,
                  size: 18,
                  color: isActive ? scheme.onPrimaryContainer : scheme.outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  book.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                    color: isActive ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
              // 勾位每行固定占位，未选中留空 —— 名字长短不一时右边缘仍然对齐
              SizedBox(
                width: 22,
                height: 22,
                child: isActive
                    ? Icon(
                        Icons.check_rounded,
                        size: 20,
                        color: scheme.primary,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
