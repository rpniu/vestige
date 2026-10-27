import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/record_book.dart';
import 'package:vestige/presentation/providers/record_book_provider.dart';
import 'package:vestige/presentation/widgets/book_name_dialog.dart';
import 'package:vestige/presentation/widgets/error_state.dart';

/// 记录本管理页：切换 / 新建 / 重命名 / 删除。
///
/// 为什么是整页而不是弹层：这里有「列表 + 新建 + 行内两个动作」，
/// 弹层里再叠输入框与确认框就是三层套娃（与「操作历史」当初升格为整页
/// 同一个理由）。
///
/// 语义上它是**承载空间**的页面，不显示任何记录内容 —— 切换后按返回即可，
/// 首页 / 统计 / 回收站已经全部换成新记录本的数据了。
class RecordBooksScreen extends ConsumerWidget {
  const RecordBooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(recordBooksProvider);
    final activeId = ref.watch(activeBookIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('记录本')),
      body: booksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // 先判 error 再判 data：出错时 data 同样是 null，
        // 落到「空列表」会让用户以为记录本都没了。
        error: (error, _) => VestigeErrorState(
          error: error,
          onRetry: () => ref.invalidate(recordBooksProvider),
        ),
        data: (books) {
          // 数据到位后校准偏好缓存：存下来的当前本可能已经不在了
          // （在别处删掉、或偏好被手工改过）。没有这一步会停在一本不存在的
          // 记录本上，看到一片空白。放到 post-frame 里做，避免 build 期间改状态。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(recordBooksControllerProvider).syncCache();
          });
          return _Body(
            books: books,
            activeId: activeId,
            onCreate: () => _create(context, ref),
            onSwitch: (book) => _switchTo(context, ref, book),
            onRename: (book) => _rename(context, ref, book),
            onDelete: (book) => _delete(context, ref, book),
          );
        },
      ),
    );
  }

  /// 删除被禁的原因（null = 可以删）。文案直接给人看，不做成枚举。
  static String? _deleteBlockedReason(
    RecordBookEntity book,
    int total,
    String activeId,
  ) {
    if (isDefaultBook(book.id)) return '默认记录本不可删除';
    if (book.id == activeId) return '正在使用，请先切换到其它记录本';
    if (total <= 1) return '至少要保留一个记录本';
    return null;
  }

  Future<void> _switchTo(
    BuildContext context,
    WidgetRef ref,
    RecordBookEntity book,
  ) async {
    final switched =
        await ref.read(recordBooksControllerProvider).switchTo(book.id);
    if (!context.mounted) return;
    _toast(context, switched ? '已切换到「${book.name}」' : '已经是这一本了');
  }

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
    // 重名会走到这里（空值与超长在弹层里已经拦住）
    _toast(context, createdBookToast(book));
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    RecordBookEntity book,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => BookNameDialog(
        title: '重命名记录本',
        confirmLabel: '保存',
        initialName: book.name,
      ),
    );
    if (name == null || !context.mounted) return;
    if (name == book.name) return;

    final ok =
        await ref.read(recordBooksControllerProvider).rename(book.id, name);
    if (!context.mounted) return;
    _toast(context, ok ? '已改名为「$name」' : '已有同名记录本，或名字不可用');
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    RecordBookEntity book,
  ) async {
    // 二次确认，且把「不可撤销」写清楚：删的是这一本的全部数据，
    // 没有回收站、也没有撤销历史可以救回来（它们随记录本一起被级联删掉）。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text('删除「${book.name}」？'),
          content: const Text(
            '这一本里的所有记录都会被永久删除，无法恢复。\n'
            '其它记录本不受影响。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await ref.read(recordBooksControllerProvider).delete(book.id);
    if (!context.mounted) return;
    _toast(context, ok ? '已删除「${book.name}」' : '这个记录本无法删除');
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.books,
    required this.activeId,
    required this.onCreate,
    required this.onSwitch,
    required this.onRename,
    required this.onDelete,
  });

  final List<RecordBookEntity> books;
  final String activeId;
  final VoidCallback onCreate;
  final ValueChanged<RecordBookEntity> onSwitch;
  final ValueChanged<RecordBookEntity> onRename;
  final ValueChanged<RecordBookEntity> onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        _Hint(
          '每个记录本是一份独立的记录，互相看不到。'
          '切换之后，首页、统计、回收站显示的都是那一本的内容。',
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: <Widget>[
              for (final (i, book) in books.indexed) ...<Widget>[
                if (i > 0) const Divider(height: 0),
                _BookRow(
                  book: book,
                  isActive: book.id == activeId,
                  blockedReason: RecordBooksScreen._deleteBlockedReason(
                    book,
                    books.length,
                    activeId,
                  ),
                  onSwitch: () => onSwitch(book),
                  onRename: () => onRename(book),
                  onDelete: () => onDelete(book),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建记录本'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: VestigeRadius.smallAll,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一行记录本。行语言与「我的」页的设置行一致：
/// 38px 图标方块 + 标题/副标题 + 行尾动作列。
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.book,
    required this.isActive,
    required this.blockedReason,
    required this.onSwitch,
    required this.onRename,
    required this.onDelete,
  });

  final RecordBookEntity book;
  final bool isActive;

  /// 删除被禁的原因（null = 可以删）。同时用作 tooltip。
  final String? blockedReason;
  final VoidCallback onSwitch;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return InkWell(
      // 当前这本点了没意义（不去抖动、也不弹「已经是了」的废话），
      // 直接不给点击反馈，视觉上靠主色标题 + 勾说明它的地位。
      onTap: isActive ? null : onSwitch,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isActive ? scheme.primaryContainer : surfaces.inset,
                borderRadius: VestigeRadius.insetAll,
                border: Border.all(
                  color: surfaces.border.withValues(alpha: 0.5),
                  width: 0.6,
                ),
              ),
              child: Icon(
                Icons.auto_stories_rounded,
                size: 20,
                color: isActive ? scheme.onPrimaryContainer : scheme.outline,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                      color: isActive ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                  Text(
                    isActive ? '当前使用' : '点按切换',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              tooltip: '重命名',
              onPressed: onRename,
            ),
            // 不可删除时按钮保留但置灰：直接消失会让人以为「这一本没有删除功能」，
            // 置灰 + tooltip 才说得清是「现在不行」。
            Tooltip(
              message: blockedReason ?? '删除这一本',
              child: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                color: scheme.error,
                onPressed: blockedReason == null ? onDelete : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部说明条：把「记录本之间互相看不到」这件事说在前面。
///
/// 不解释的后果很具体：用户新建一本以为能「汇总」两本的内容，
/// 结果发现旧记录不见了，第一反应是数据丢了。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      // 实色 primaryContainer，不用半透明调色（本 App 的表面色一律实色，
      // 半透明叠出来的底色会糊成一片灰）。
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: VestigeRadius.smallAll,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onPrimaryContainer,
          height: 1.5,
        ),
      ),
    );
  }
}
