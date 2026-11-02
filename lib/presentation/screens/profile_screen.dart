import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/motion.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/data/config/home_layout_config.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/book_plan.dart';
import 'package:vestige/domain/csv_util.dart';
import 'package:vestige/presentation/providers/home_layout_provider.dart';
import 'package:vestige/presentation/providers/package_info_provider.dart';
import 'package:vestige/presentation/providers/record_book_provider.dart';
import 'package:vestige/presentation/providers/records_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';
import 'package:vestige/presentation/services/csv_file.dart';
import 'package:vestige/presentation/widgets/center_dialog.dart';
import 'package:vestige/presentation/widgets/undo_snack_bar.dart';

/// 我的：主题、数据管理（CSV 文件导入 / 导出）、关于。
///
/// 数据管理一律走**真实文件**：
/// - 导出：桌面端用 `file_selector` 弹原生「另存为」；Android / iOS 用
///   `flutter_file_dialog` 弹系统保存界面（SAF「保存到」/ iOS「存储到文件」），
///   由用户选定位置后由插件写盘。两条路都不经过系统分享。
/// - 导入：选一个 .csv 文件 → 解析 → 把结果（条数 / 补记条数 / 跳过的坏行）
///   摊开给用户确认 → 再写库。避免选错文件就直接改数据。
///   写库后提示条带「撤销」：覆盖的还原、新增的删除，一步回到导入前
///   （同一步也进「操作历史」，提示条消失后仍可回退）。
///
/// 2026-10-27：Web 目标已移除，原先为它保留的「分享文本 / 下载」分支一并删掉。
/// 2026-10-28：移动端原本回落到 `share_plus` 分享面板，改为系统保存对话框 ——
/// 导出是「把文件存到我的设备上」，不是「发给别人」。
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  /// CSV 类型过滤器：各平台认的字段不同——Android 看 mimeTypes、
  /// iOS/macOS 看 UTI、桌面看 extensions，所以三个都给上。
  static const List<XTypeGroup> _csvTypeGroups = <XTypeGroup>[
    XTypeGroup(
      label: 'CSV 文件',
      extensions: <String>['csv'],
      mimeTypes: <String>[
        'text/csv',
        'text/comma-separated-values',
        'text/plain',
      ],
      uniformTypeIdentifiers: <String>['public.comma-separated-values-text'],
    ),
  ];

  /// 「用户主动取消保存」的哨兵，用来和「平台不支持另存为」区分开。
  static const String _cancelled = '\u0000cancelled';

  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(themeProvider);
    final stats = ref.watch(recordStatsProvider);
    // 读取失败时不能把「共 0 条记录」当成事实展示（2026-10-27 审查 C-001）：
    // 头卡改为显示失败，数据管理入口照旧可用（导出/导入会自己报错）。
    final recordsFailed = ref.watch(recordsProvider).hasError;
    final layout = ref.watch(homeButtonLayoutProvider);
    // 记录本名字与总数读的是偏好里的缓存（不碰数据库 —— 这一行不值得为它开库）
    final activeBook = ref.watch(activeBookProvider);
    final bookName = activeBook.name;
    final bookCount = activeBook.count;

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _HeaderCard(stats: stats, failed: recordsFailed),
          const SizedBox(height: 24),

          _SectionTitle('配色方案'),
          Card(
            child: Column(
              children: <Widget>[
                for (final (i, variant)
                    in AppThemeVariant.values.indexed) ...<Widget>[
                  if (i > 0) const Divider(height: 0),
                  _OptionTile(
                    leading: _PalettePreview(variant: variant),
                    title: variant.title,
                    subtitle: variant.description,
                    selected: settings.variant == variant,
                    onTap: () =>
                        ref.read(themeProvider.notifier).setVariant(variant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          _SectionTitle('显示模式'),
          Card(
            child: Column(
              children: <Widget>[
                for (final (i, mode) in ThemeMode.values.indexed) ...<Widget>[
                  if (i > 0) const Divider(height: 0),
                  _OptionTile(
                    leading: _ModeIcon(mode: mode),
                    title: themeModeLabel(mode),
                    selected: settings.mode == mode,
                    onTap: () => ref.read(themeProvider.notifier).setMode(mode),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          _SectionTitle('首页按钮位置'),
          Card(
            child: Column(
              children: <Widget>[
                for (final (i, side) in ButtonSide.values.indexed) ...<Widget>[
                  if (i > 0) const Divider(height: 0),
                  _OptionTile(
                    leading: const _SideIcon(
                      icon: Icons.switch_access_shortcut_rounded,
                    ),
                    title: side == ButtonSide.left ? '靠左' : '靠右',
                    subtitle: i == 0 ? '「记一笔」、计时胶囊与「到底」按钮停靠的屏幕侧' : null,
                    selected: layout == side,
                    onTap: () => ref
                        .read(homeButtonLayoutProvider.notifier)
                        .setSide(side),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          _SectionTitle('记录本'),
          Card(
            child: _ActionTile(
              icon: Icons.auto_stories_rounded,
              // 直接显示当前记录本的名字：切换是不常见的操作，
              // 但「我现在在哪一本上」是随时可能要确认的信息。
              title: bookName,
              subtitle: bookCount > 1
                  ? '共 $bookCount 个记录本 · 点此切换'
                  : '点此新建记录本或切换到其它一本',
              enabled: !_busy,
              onTap: () => context.push(AppRoutes.recordBooks),
            ),
          ),
          const SizedBox(height: 24),

          _SectionTitle('数据管理'),
          Card(
            child: Column(
              children: <Widget>[
                _ActionTile(
                  icon: Icons.file_download_outlined,
                  title: '导出 CSV 文件',
                  subtitle: '选择记录本，导出成一个文件',
                  enabled: !_busy,
                  onTap: _exportCsv,
                ),
                const Divider(height: 0),
                _ActionTile(
                  icon: Icons.file_open_outlined,
                  title: '从文件导入 CSV',
                  subtitle: '选择 .csv 文件，兼容旧版 6 列格式',
                  enabled: !_busy,
                  onTap: _pickCsvAndImport,
                ),
                const Divider(height: 0),
                _ActionTile(
                  icon: Icons.delete_outline_rounded,
                  title: '回收站',
                  subtitle: '管理已删除的记录',
                  enabled: !_busy,
                  onTap: () => context.push(AppRoutes.trash),
                ),
                const Divider(height: 0),
                _ActionTile(
                  icon: Icons.history_rounded,
                  title: '操作历史',
                  subtitle: '回退批量改标签、平移日期、删除等操作',
                  enabled: !_busy,
                  onTap: _openUndoHistory,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _SectionTitle('关于'),
          Card(
            child: _ActionTile(
              icon: Icons.info_outline_rounded,
              // 版本号读系统安装清单（打包时 --build-name 写入，CI 发版 =
              // tag 版本），不再手写 —— 发了 v1.1.0 这里就显示 v1.1.0。
              title:
                  'Vestige ${ref.watch(packageInfoProvider).valueOrNull?.version ?? ''}',
              subtitle: '记录日期与入库时间分离，支持随时随地补记',
              onTap: _showAbout,
            ),
          ),
        ],
      ),
    );
  }

  // ── 导出 ────────────────────────────────────────────────────────────

  /// 打开「操作历史」页（多步回退）。
  ///
  /// 放在这里而不是 SnackBar 上：SnackBar 只够退最近一步，
  /// 而真正需要回退的场景常常发生在提示消失之后，甚至第二天才反应过来。
  ///
  /// 以整页推入（与「回收站」同构）—— 之前是居中弹层，弹层高度再大也只有
  /// 屏高八成，历史一长就得在小框里滚，且弹层里再叠确认框容易「层压层」。
  void _openUndoHistory() => context.push(AppRoutes.undoHistory);

  /// 导出：先选记录本，再把它们写进**一个** CSV 文件。
  ///
  /// 只有一本时跳过选择弹层 —— 只有一道选项的弹层只是多一次点击。
  Future<void> _exportCsv() async {
    final books = await ref.read(recordBooksProvider.future);
    if (!mounted) return;
    if (books.isEmpty) {
      _toast('还没有记录本');
      return;
    }

    // 默认全选：导出的意图绝大多数是「备份我的数据」，
    // 默认只勾当前本会让用户在别的本上长期漏备份而不自知。
    final List<String>? picked = books.length == 1
        ? <String>[books.first.id]
        : await showVestigeCenterDialog<List<String>>(
            context: context,
            maxHeightFactor: 0.7,
            builder: (BuildContext context) => _ExportBookDialog(
              books: books,
              activeBookId: ref.read(activeBookIdProvider),
            ),
          );
    if (picked == null || picked.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      final export = await ref.read(recordActionsProvider).exportCsv(picked);
      // 所选记录本都是空的：不必生成一个只有表头的文件
      if (export.isEmpty) {
        _toast('所选记录本里没有可导出的记录');
        return;
      }
      final fileName = _exportFileName(export);

      // 1) 桌面端：file_selector 的原生「另存为」
      final path = await _pickSavePath(fileName);
      if (path == _cancelled) return; // 用户取消
      if (path != null) {
        final ok = await writeCsvToPath(path, export.csv);
        if (mounted) {
          _toast(
            ok
                ? '已导出 ${export.count} 条（${export.bookLabel}）到 $path'
                : '写入文件失败：$path',
          );
        }
        return;
      }

      // 2) 移动端：系统保存对话框（Android = SAF「保存到」，iOS = 存储到「文件」）。
      //    直接传字节，插件在用户确认位置后写盘，不经过系统分享；取消返回 null。
      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(utf8.encode(export.csv)),
          fileName: fileName,
          mimeTypesFilter: const <String>['text/csv'],
        ),
      );
      if (!mounted || saved == null) return; // 用户取消
      _toast('已导出 ${export.count} 条（${export.bookLabel}）到 ${_readablePath(saved)}');
    } on PlatformException catch (e) {
      // activity_not_found：设备没有能承接 ACTION_CREATE_DOCUMENT 的
      // 文件管理器（精简 ROM 上可能发生），此时告知用户比抛原始错误码有用。
      if (!mounted) return;
      _toast(
        e.code == 'activity_not_found'
            ? '系统里没有可用的文件管理器，无法选择保存位置'
            : '导出失败：${e.message ?? e.code}',
      );
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出文件名：带上记录本名字，否则多个备份文件只靠时间戳区分，过几天就分不清。
  ///
  /// 单个记录本 → `vestige_学习_<毫秒>.csv`；多个 → `vestige_3个记录本_<毫秒>.csv`。
  /// 名字里的文件系统保留字符替换成 `_`（record_books 允许任意字符，
  /// 但 `/`、`:` 这类字符出现在文件名里会被系统拒绝或截断）。
  String _exportFileName(CsvExport export) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final label = export.bookNames.length == 1
        ? export.bookNames.values.first
        : '${export.bookNames.length}个记录本';
    final safe = _sanitizeFileLabel(label);
    return 'vestige_${safe}_$stamp.csv';
  }

  static String _sanitizeFileLabel(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (cleaned.isEmpty) return 'export';
    // 各平台对文件名长度都有上限，留足时间戳与后缀的余量
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  /// Android 的保存对话框回的是 SAF document path（形如
  /// `/document/primary:Download/x.csv`），去掉协议前缀才好读；
  /// iOS 与桌面回的是真实绝对路径，原样显示。
  String _readablePath(String raw) =>
      raw.replaceFirst(RegExp(r'^/document/[^/:]*:'), '');

  /// 调起原生保存对话框。返回用户选定路径；
  /// 返回 [_cancelled] = 用户取消；返回 null = 平台没有该能力（Android / iOS），
  /// 调用方应改走系统保存对话框。
  ///
  /// 只把「平台没实现」当作不支持（2026-10-27 审查 m-005）：权限不足、磁盘满这类
  /// 真实故障必须上抛，否则会被静默当成「不支持另存为」而改走别路 ——
  /// 用户会以为导出成功了，实际什么也没写。
  Future<String?> _pickSavePath(String suggestedName) async {
    try {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: _csvTypeGroups,
        confirmButtonText: '保存',
      );
      final path = location?.path;
      if (path == null || path.isEmpty) return _cancelled;
      return path;
    } on UnimplementedError {
      return null; // file_selector 的 Android / iOS 实现没有另存为
    } on UnsupportedError {
      return null;
    }
  }

  // ── 导入 ────────────────────────────────────────────────────────────

  Future<void> _pickCsvAndImport() async {
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: _csvTypeGroups,
        confirmButtonText: '导入',
      );
      if (file == null || !mounted) return; // 用户取消选择

      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final (text, isUtf8) = CsvUtil.decodeBytes(bytes);

      final preview = CsvUtil.parse(text);
      if (preview.isEmpty) {
        _toast(preview.summary());
        return;
      }

      // 预览里的记录本去向用**和写库同一份规则**算出来（domain/book_plan.dart），
      // 否则会出现「预览说会新建一本，实际写进了默认本」这种说不清的事。
      final plan = await _planImportBooks(preview);
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _ImportPreviewDialog(
          fileName: file.name,
          sizeLabel: '${(bytes.length / 1024).toStringAsFixed(1)} KB',
          preview: preview,
          bookPlan: plan,
          looksUtf8: isUtf8,
        ),
      );
      if (confirmed != true || !mounted) return;

      final outcome = await ref
          .read(recordActionsProvider)
          .importRecords(preview.records, bookNames: preview.bookNames);
      // 新建了记录本时同步偏好缓存（「我的」页副标题与总数读的是那份缓存，
      // 记录本列表本身走数据库流，会自己刷新）
      if (outcome.createdBooks.isNotEmpty) {
        await ref.read(recordBooksControllerProvider).syncCache();
      }
      if (!mounted) return;
      // 带「撤销」的提示：导入是本 App 唯一「批量且破坏性」的入口，
      // 覆盖既有记录、又可能一次写进来几百条新增，后悔的窗口必须先给出来。
      // 提示条之外还有兜底 —— 同一步也进了「操作历史」（20 步、不过期）。
      final bookNote = outcome.bookNote(
        currentBookName: ref.read(activeBookNameProvider),
      );
      _toastUndoable(
        '已从「${file.name}」导入 ${outcome.written} 条'
        '（${outcome.breakdown}'
        '${bookNote.isEmpty ? '' : '，$bookNote'}'
        '${preview.backfilledCount > 0 ? '，其中补记 ${preview.backfilledCount} 条' : ''}）',
      );
    } catch (e) {
      if (mounted) _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 预览用：把文件里的记录本算成「落到哪一本」。
  ///
  /// 只读，不新建 —— 真正的新建发生在用户确认之后的写库事务里。
  Future<List<BookPlanEntry>> _planImportBooks(CsvImportResult preview) async {
    final books = await ref.read(bookDaoProvider).getAll();
    return planBooks(
      counts: preview.bookCounts,
      names: preview.bookNames,
      existingIdNames: {for (final b in books) b.id: b.name},
      existingNames: {for (final b in books) b.name: b.id},
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        // 爪印坐进主色圆角方块（与页头卡头像同款造型）——
        // 裸图标太单薄，App 的「脸面」值得一个正经的品牌位。
        icon: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: VestigeRadius.insetAll,
          ),
          child: Icon(
            Icons.pets_rounded,
            size: 26,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
        title: const Text('关于 Vestige'),
        content: const Text(
          '一个纯粹本地的记录 App：所有数据只存在你自己的设备上，不联网。\n\n'
          '记录有两个时间：\n'
          '· 记录日期（可修改）——这条记录「属于」哪一天；\n'
          '· 入库时间（只读）——这条数据实际被写下来的时刻。\n\n'
          '两者不是同一天时，就说明这是一条「补记」。'
          '忘了记不要紧，补上就好。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
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

  /// 显示一条带「撤销」的提示（导入用）。
  ///
  /// 约束集中在 [showUndoableSnackBar]：`lastUndoEntryId` 定位「刚做的这一步」、
  /// `persist: false`、3 秒时长、拿不到条目时不挂按钮。
  void _toastUndoable(String message) => showUndoableSnackBarOf(
        context,
        message: message,
        entryId: ref.read(recordActionsProvider).lastUndoEntryId,
        onUndo: (int entryId) => ref.read(recordActionsProvider).undoUpTo(entryId),
      );
}

/// 导出前选记录本：多选，**默认全选**。
///
/// 为什么默认全选：导出的绝大多数用途是「备份我的数据」。默认只勾当前本，
/// 用户在别的本上就会长期漏备份，而且不会意识到 —— 备份缺口是最不该
/// 靠用户自己发现的那类问题。
///
/// 返回值：选中的记录本 id（按列表顺序）；取消/关闭返回 null。
class _ExportBookDialog extends StatefulWidget {
  const _ExportBookDialog({required this.books, required this.activeBookId});

  final List<RecordBookEntity> books;

  /// 当前正在用的那本，只用来在行尾打个「当前」标记。
  final String activeBookId;

  @override
  State<_ExportBookDialog> createState() => _ExportBookDialogState();
}

class _ExportBookDialogState extends State<_ExportBookDialog> {
  late final Set<String> _picked = <String>{
    for (final b in widget.books) b.id,
  };

  bool get _allPicked => _picked.length == widget.books.length;

  void _toggle(String id, bool selected) => setState(() {
        if (selected) {
          _picked.add(id);
        } else {
          _picked.remove(id);
        }
      });

  void _toggleAll() => setState(() {
        if (_allPicked) {
          _picked.clear();
        } else {
          _picked.addAll(<String>[for (final b in widget.books) b.id]);
        }
      });

  void _confirm() {
    Navigator.of(context).pop(<String>[
      for (final b in widget.books)
        if (_picked.contains(b.id)) b.id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '导出哪几个记录本',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '选中的记录本会写进同一个 CSV 文件；导入时按记录本分别归位。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            // 记录本可能很多（没有上限），列表自己在弹层里滚
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final book in widget.books)
                    CheckboxListTile(
                      value: _picked.contains(book.id),
                      onChanged: (bool? v) => _toggle(book.id, v ?? false),
                      title: Text(book.name),
                      subtitle: book.id == widget.activeBookId
                          ? const Text('当前记录本')
                          : null,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: _toggleAll,
                  child: Text(_allPicked ? '全不选' : '全选'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _picked.isEmpty ? null : _confirm,
                  child: Text(
                    _allPicked
                        ? '全部导出'
                        : '导出 ${_picked.length} 个',
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

/// 导入预览确认框：把「文件是谁、会写进去什么、哪些行会被丢掉」讲清楚。
class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({
    required this.fileName,
    required this.sizeLabel,
    required this.preview,
    required this.bookPlan,
    required this.looksUtf8,
  });

  final String fileName;
  final String sizeLabel;
  final CsvImportResult preview;

  /// 每个记录本的落点（与写库时同一份规则算出来的）。
  final List<BookPlanEntry> bookPlan;

  final bool looksUtf8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);

    return AlertDialog(
      title: const Text('导入这个文件？'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _row(context, '文件', '$fileName（$sizeLabel）'),
            _row(context, '将导入', '${preview.records.length} 条'),
            if (preview.backfilledCount > 0)
              _row(
                context,
                '其中补记',
                '${preview.backfilledCount} 条',
                color: tokens.backfill,
              ),
            if (preview.skipped > 0)
              _row(context, '跳过', '${preview.skipped} 行', color: scheme.error),
            const SizedBox(height: 6),
            // 记录本去向必须摊开：导入会往不同的本里写，用户得先知道
            // 「这些记录会出现在哪里」，事后才不至于以为数据丢了。
            Text(
              '记录本',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            for (final entry in bookPlan)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  '· 「${entry.label}」 ${entry.count} 条'
                  '${entry.target == BookTarget.existing ? '' : '（${entry.note}）'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: entry.target == BookTarget.fallback
                        ? scheme.onSurfaceVariant
                        : null,
                    height: 1.4,
                  ),
                ),
              ),
            if (!preview.hasBookColumn) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '这个文件是旧版导出的（不含记录本信息），全部导入默认记录本。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            if (preview.errors.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                preview.errors.take(3).join('\n'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            if (!looksUtf8) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: VestigeRadius.smallAll,
                ),
                child: Text(
                  '这个文件不是 UTF-8 编码（可能是 Excel / Windows 导出的 GBK），'
                  '非英文字符可能显示异常。建议先另存为 UTF-8 再导入。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'ID 相同的记录会被文件里的版本覆盖，其余新增。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('导入'),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    Color? color,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: color == null ? null : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.stats, this.failed = false});

  final RecordStats stats;

  /// 记录读不出来（库打不开 / 查询失败）。此时数字没有任何意义，
  /// 必须显式说明，而不是显示「共 0 条记录」。
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      elevation: 1.2,
      shadowColor: scheme.primary.withValues(alpha: 0.12),
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(
          color: scheme.primary.withValues(alpha: 0.18),
          width: 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 右上角大号半透明爪印 —— 让头卡有「签名感」，而不只是一块
            // 主色色块。透明度压到 0.08，不与文字抢注意力；卡片主题是
            // antiAlias 裁切，出血部分被 24 圆角裁掉，不会溢出。
            Positioned(
              right: -14,
              top: -14,
              child: Icon(
                Icons.pets_rounded,
                size: 92,
                color: scheme.primary.withValues(alpha: 0.08),
              ),
            ),
            // 原来的整行内容（头像 + 文案）作为 Stack 的第二个孩子，
            // 保持在 Row 里 —— Expanded 只能活在 Row/Column 里。
            Row(
              children: <Widget>[
                // 圆角方形头像（不是圆形）：本 App 的形状语言是圆角矩形 ——
                // 卡片 24、徽标 12、FAB 18，圆形只留给状态点。
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: VestigeRadius.insetAll,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.22),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.pets_rounded,
                    color: scheme.onPrimary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        failed ? '记录读取失败' : '共 ${stats.totalCount} 条记录',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: failed ? scheme.error : scheme.primary,
                            )
                            .tabular,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        failed
                            ? '数据可能仍在本地，请在首页重试一次'
                            : '活跃 ${stats.activeDays} 天 · 连续 ${stats.streak} 天'
                                  '${stats.backfilledCount > 0 ? ' · 补记 ${stats.backfilledCount} 条' : ''}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(
                              color: scheme.onPrimaryContainer.withValues(
                                alpha: 0.85,
                              ),
                              fontWeight: FontWeight.w600,
                            )
                            .tabular,
                      ),
                    ],
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

/// 单选设置行：配色方案 / 显示模式两张卡共用的「行语言」。
///
/// 原来是裸 `RadioListTile`（一个圆圈 + 一行字）：行右大片留白，和同页
/// 「数据管理」卡（图标方块 + 标题 + 副标题 + 箭头）摆在一起像两个 App。
/// 现在与数据管理行同构：左 leading（图标方块 / 色板）、中标题与副标题、
/// 行尾选中勾 —— 勾位每行都占着（未选中留空），勾才是一列对齐的
/// （与统计页年份弹层同一写法）。
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      checked: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                        // 选中行标题上主色：三张卡扫过去，「现在生效的是哪行」
                        // 不用挨个找勾。
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 24,
                height: 24,
                // 勾位固定占位（与统计页年份弹层同一写法），勾的出现用
                // AnimatedScale（fast 档）：从小到大弹出，比硬出现柔和，
                // 占位不变所以行高稳定。
                child: AnimatedScale(
                  duration: VestigeMotion.fast,
                  curve: VestigeMotion.curve,
                  scale: selected ? 1 : 0,
                  child: selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 20,
                          color: scheme.primary,
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 显示模式行的 leading：38px 图标方块，与「数据管理」行同一尺寸语言。
class _ModeIcon extends StatelessWidget {
  const _ModeIcon({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };
    final surfaces = VestigeSurfaces.of(context);
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: VestigeRadius.insetAll,
        border: Border.all(
          color: surfaces.border.withValues(alpha: 0.5),
          width: 0.6,
        ),
      ),
      child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
    );
  }
}

/// 首页按钮位置行的 leading：38px 图标方块，与 [_ModeIcon] 同一尺寸语言。
class _SideIcon extends StatelessWidget {
  const _SideIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = VestigeSurfaces.of(context);
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: VestigeRadius.insetAll,
        border: Border.all(
          color: surfaces.border.withValues(alpha: 0.5),
          width: 0.6,
        ),
      ),
      child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
    );
  }
}

/// 配色方案行的 leading：2×2 迷你色板。
///
/// 整个「我的」页的 leading 都是 38px 圆角方块（显示模式 / 数据管理 / 关于），
/// 色板也凑成同一尺寸，几张卡的左列才在一条垂线上。
/// 底色直接用这个配色的 primaryContainer —— 色板本身就是「这套配色长这样」
/// 的预览，不需要额外的中性底座。
class _PalettePreview extends StatelessWidget {
  const _PalettePreview({required this.variant});

  final AppThemeVariant variant;

  @override
  Widget build(BuildContext context) {
    final palette = vestigeColorScheme(variant, Brightness.light);
    return Container(
      width: 38,
      height: 38,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: palette.primaryContainer,
        borderRadius: VestigeRadius.insetAll,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _dot(palette.primary),
              _dot(palette.secondaryContainer),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _dot(palette.tertiaryContainer),
              _dot(palette.onPrimaryContainer),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        spacing: 8,
        children: <Widget>[
          // 主色小竖条 —— 和首页日期分组头用的是同一套「分节」语言，
          // 两个页面因此在结构上看起来是一家人。
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            text,
            // 从主色小字改成 onSurface 粗体：主色在这里被用了太多次，
            // 反而和卡片里的可点文字（也是主色）抢注意力。
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      enabled: enabled,
      // 图标坐进圆角方块：设置页的每一行因此有了统一的「起点」，
      // 裸图标直接摆在文字左边时，几行之间的图标光学重心是飘的。
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: enabled ? scheme.primaryContainer : surfaces.inset,
          borderRadius: VestigeRadius.insetAll,
          border: Border.all(
            color: surfaces.border.withValues(alpha: 0.5),
            width: 0.6,
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: enabled ? scheme.onPrimaryContainer : scheme.outline,
        ),
      ),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: scheme.outline,
      ),
      onTap: enabled ? onTap : null,
    );
  }
}
