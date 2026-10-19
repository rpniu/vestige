import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/providers/edit_record_provider.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

/// 编辑 / 新建 / 补记页。
///
/// 本页是「补交」体验的核心：
/// - 顶部第一块就是**记录日期**（可随意改成过去的某天），配 今天/昨天/前天 快捷按钮；
/// - 时间也可以单独改（默认沿用当前时刻，不会是 00:00）；
/// - 标题下方实时提示「这条会被记为 补记 / 今天」，保存前就心里有数；
/// - 既有记录的**入库时间只读**，避免编辑动作污染审计信息。
class EditScreen extends ConsumerStatefulWidget {
  const EditScreen({super.key, this.recordId, this.initialDay});

  /// 为空表示新建。
  final String? recordId;

  /// 新建时预置的业务日期（补记入口传昨天进来）。
  final DateTime? initialDay;

  @override
  ConsumerState<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends ConsumerState<EditScreen> {
  late final String _key = editRecordKey(
    recordId: widget.recordId,
    initialDay: widget.initialDay,
  );

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(editRecordProvider(_key));
    final controller = ref.watch(editRecordProvider(_key).notifier);

    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('加载失败：$error')),
      ),
      data: (state) => _EditBody(
        state: state,
        controller: controller,
        showBackfillHint: widget.initialDay != null && widget.recordId == null,
      ),
    );
  }
}

class _EditBody extends StatelessWidget {
  const _EditBody({
    required this.state,
    required this.controller,
    required this.showBackfillHint,
  });

  final EditRecordState state;
  final EditRecordController controller;
  final bool showBackfillHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.isNew ? (state.isBackfilled ? '补记' : '新建记录') : '编辑记录',
        ),
        actions: <Widget>[
          if (!state.isNew)
            IconButton(
              tooltip: '移入回收站',
              icon: Icon(Icons.delete_outline, color: scheme.error),
              onPressed: () => _confirmDelete(context),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          if (showBackfillHint) ...<Widget>[
            _HintCard(
              icon: Icons.history_edu_outlined,
              title: '补记模式',
              message: '日期已预置为昨天，可改成任意过去的日子；'
                  '内容和当天记的一样，保存后会打上「补记」标记。',
            ),
            const SizedBox(height: 16),
          ],
          _RecordTimeCard(state: state, controller: controller),
          const SizedBox(height: 16),
          _TitleField(state: state, controller: controller),
          const SizedBox(height: 16),
          _ContentField(state: state, controller: controller),
          const SizedBox(height: 16),
          _TagsSection(state: state, controller: controller),
          if (!state.isNew) ...<Widget>[
            const SizedBox(height: 16),
            _MetaCard(state: state),
          ],
          if (state.error != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              state.error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
      // 保存是这一页的主操作，钉在底部常驻（理由见 [_SaveBar]）。
      bottomNavigationBar: _SaveBar(
        isSaving: state.isSaving,
        onPressed: state.canSave ? () => _save(context) : null,
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final ok = await controller.save();
    if (!context.mounted) return;
    if (ok) {
      Navigator.of(context).maybePop();
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('内容不能为空')));
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移入回收站？'),
        content: const Text('记录会进入回收站，之后可以恢复或彻底删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await controller.delete();
    if (ok && context.mounted) Navigator.of(context).maybePop();
  }
}

/// 钉在底部的保存栏。
///
/// 为什么不沿用「列表最后一个按钮」：这一屏的高度会随系统字号、标签数量、
/// 是否编辑已有记录（多一张元信息卡）浮动，保存按钮经常落在首屏之外 ——
/// 主操作不该需要先滚到底才找得到。放进 `bottomNavigationBar` 后它常驻底部，
/// 而且 Scaffold 在软键盘弹起时会把它一起顶到键盘上方，打字中间也能直接保存。
///
/// 底色用页面底 [VestigeSurfaces.base] 而不是容器白：它是一条「栏」，
/// 不是一张卡片；靠顶部一条描边和滚动内容分界就够了。
class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.isSaving, required this.onPressed});

  final bool isSaving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final surfaces = VestigeSurfaces.of(context);

    return Container(
      decoration: BoxDecoration(
        color: surfaces.base,
        border: Border(top: BorderSide(color: surfaces.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: onPressed,
              icon: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(isSaving ? '保存中…' : '保存'),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「具体是哪一天」的快捷项：`(文案, 相对今天偏移的天数)`。
/// 「今天 / 记过去」不在这里 —— 那个由上面的分段开关负责。
const List<(String, int)> _quickDays = <(String, int)>[
  ('昨天', -1),
  ('前天', -2),
  ('上周今天', -7),
];

/// 记录日期 / 时间卡片 —— 补记的一等公民。
///
/// 卡片里只有**一个**时间面板（[_TimePanel]），且它现在只走图形化入口：
/// 一行日期（日历）、一行时间（时钟）。2026-09-17 的两次改版删掉了
/// 「1 / 2」编号 +「或」分隔线，又删掉了年月日 / 时分的数字输入框 ——
/// 前者读起来像必须二选一，后者则把一台「选择器」拆成了五个小控件。
class _RecordTimeCard extends StatelessWidget {
  const _RecordTimeCard({required this.state, required this.controller});

  final EditRecordState state;
  final EditRecordController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = VestigeTokens.of(context);
    final surfaces = VestigeSurfaces.of(context);
    final offset = state.dayOffsetFromToday;

    final (label, chipOn, chipContainer) = switch (offset) {
      0 => ('今天记录', scheme.onPrimaryContainer, scheme.primaryContainer),
      1 => ('补记 · 昨天', tokens.onBackfillContainer, tokens.backfillContainer),
      > 1 => (
          '补记 · $offset 天前',
          tokens.onBackfillContainer,
          tokens.backfillContainer,
        ),
      _ => ('未来日期 · 尚未发生', scheme.onErrorContainer, scheme.errorContainer),
    };

    return Card(
      elevation: 0.8,
      shadowColor: scheme.shadow.withValues(alpha: 0.05),
      color: surfaces.card,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(color: surfaces.border, width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 3.5,
                  height: 14,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Text(
                    '记录日期（可改）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: chipContainer,
                    borderRadius: VestigeRadius.pillAll,
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: chipOn,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 「是否补交」的唯一开关：新建和补记本来就是同一件事，
            // 只是业务日期落在今天还是过去。选完这个再挑具体是哪天。
            SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.today_outlined, size: 17),
                  label: Text('今天记'),
                ),
                ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.history_toggle_off, size: 17),
                  label: Text('记过去'),
                ),
              ],
              selected: <bool>{!state.isRecordedToday},
              showSelectedIcon: false,
              // 铺满整行：默认是按内容宽度居中，一行里左边空一截，
              // 和上面的标题、下面的面板都不对齐。宽度相等的两半看着才像「二选一」。
              expandedInsets: EdgeInsets.zero,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selection) {
                if (selection.first) {
                  controller.startBackfill();
                } else {
                  controller.resetToNow();
                }
              },
            ),
            const SizedBox(height: 14),
            // 面板只留图形化入口（详见 [_TimePanel]）：日期一行、时间一行，
            // 整行可点，行尾是日历 / 时钟按钮。
            _TimePanel(
              recordedAt: state.recordedAt,
              onPickDate: _pickDate,
              onPickTime: _pickTime,
            ),
            const SizedBox(height: 10),
            const _PanelHint(),
            const SizedBox(height: 14),
            // 这里只放「具体是哪一天」的快捷项；「今天 / 记过去」由上面的分段开关决定。
            // 三颗统一不带图标 —— 只有一颗带图标时，三颗就不像一套东西了。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (label, delta) in _quickDays)
                  ActionChip(
                    label: Text(label),
                    onPressed: () => controller.shiftRecordedDay(delta),
                    side: BorderSide(color: surfaces.border),
                    backgroundColor: Colors.transparent,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (state.isBackfilled) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.history_toggle_off, size: 15, color: tokens.backfill),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '这条是补记：归属 ${dayKey(state.recordedAt)}，'
                      '入库时间 ${dateTimeLabel(state.createdAt!)}'
                      '${state.backfillDelayDays > 0 ? '（隔了 ${state.backfillDelayDays} 天）' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tokens.backfill,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      locale: const Locale('zh', 'CN'),
      initialDate: state.recordedAt.isAfter(now) ? now : state.recordedAt,
      firstDate: DateTime(2000),
      // 不允许记录未来：补记是「补交过去」，往前没有边界，往后没有意义
      lastDate: now,
      helpText: '选择这条记录归属的日期',
      confirmText: '确定',
      cancelText: '取消',
    );
    if (picked != null) controller.setRecordedDay(picked);
  }

  Future<void> _pickTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(state.recordedAt),
      helpText: '选择记录的时刻',
      confirmText: '确定',
      cancelText: '取消',
    );
    if (picked != null) controller.setRecordedTime(picked.hour, picked.minute);
  }
}

/// 面板下面那行小字：说清这行「值 + 按钮」是怎么改的。
class _PanelHint extends StatelessWidget {
  const _PanelHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.touch_app_outlined,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            // 盘面里已经没有可敲的东西了，这行只需说明「哪能点」。
            // 长度控制在 412 宽下**一行放得下**（多一行会显得比面板还啰嗦）。
            '点这一行，用日历 / 时钟挑日期和时刻。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// 每行末尾的图形化入口（日期行挂日历、时间行挂时钟）。
///
/// 用**填充色**（主色容器色）而不是描边：面板是凹槽底 + 一行文字，只有填色
/// 才能一眼看出「这一块是按钮」，其余部分均为只读的值。
/// 两行的按钮右边缘对齐成一列，读起来才是一列操作。
class _PickerButton extends StatelessWidget {
  const _PickerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.primaryContainer,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: VestigeRadius.insetAll,
          side: BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 19, color: scheme.onPrimaryContainer),
          ),
        ),
      ),
    );
  }
}

/// 时间面板 —— 「记录日期」卡里唯一的时间入口：只有日历 / 时钟两条图形化入口。
///
/// 2026-09-17 二次改版：**删掉键盘输入**。
/// 上一版把「1 直接输入 / 或 / 2 用日历、时钟选择」合并进了同一个面板，但主入口
/// 仍然是五个数字框（年月日时分），日历 / 时钟只是挂在行尾的两个附属按钮。
/// 实际用下来这套主次是反的：
/// - 改时间只有两种诉求 —— 「改成昨天 / 前天」（下面有快捷 chip）和「精确挑一个时刻」，
///   前者用不着键盘，后者反而是日历 / 时钟点两下更快；
/// - 五个小格子各自带着「聚焦全选 / 满格跳下一格 / 失焦夹取越界值」一整套规矩，
///   为的是扛住「敲了一个 `1` 到底算 1 月还是 12 月的前半截」这种半成品输入；
///   输入框一删，这套 compose / clamp 逻辑连同它的边界情况一起消失了；
/// - 面板里「带描边的输入框」和「填充色的按钮」混在一起，也不像一台选择器。
///
/// 现在结构极简：两行等距入口 —— 左标签（日期 / 时间）、中间当前值、行尾图标按钮。
/// **整行可点**：44 宽的图标按钮钉在行尾，单手拇指够不着，整行可点把命中区从 44
/// 放大到整行；按钮本身保留，是因为凹槽面上只有一行文字值时，用户不一定知道
/// 「点它会发生什么」，填充色的按钮才是「这里能点」的视觉锚点。
class _TimePanel extends StatelessWidget {
  const _TimePanel({
    required this.recordedAt,
    required this.onPickDate,
    required this.onPickTime,
  });

  final DateTime recordedAt;

  /// 打开日历 / 时钟。传 `BuildContext` 是因为要交给 `showDatePicker` 定位弹层。
  final Future<void> Function(BuildContext context) onPickDate;
  final Future<void> Function(BuildContext context) onPickTime;

  @override
  Widget build(BuildContext context) {
    final surfaces = VestigeSurfaces.of(context);

    // 底色挂在 Material 上而不是套一层 Container：Container 的实色背景会盖在
    // Material 的 ink 层之上，整行 InkWell 的水波纹就再也看不见了。
    return Material(
      color: surfaces.inset,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.smallAll,
        side: BorderSide(color: surfaces.border),
      ),
      child: Column(
        children: <Widget>[
          _entry(
            context,
            label: '日期',
            value: fullDateLabel(recordedAt),
            icon: Icons.event_outlined,
            tooltip: '用日历挑选日期',
            onTap: () => onPickDate(context),
          ),
          // 面板内的分隔线用一根实色细线，不用 Divider —— Divider 会带上主题里的
          // 上下留白，在面板这种紧凑容器里会把两行推得太开。
          Container(height: 1, color: surfaces.border),
          _entry(
            context,
            label: '时间',
            value: timeLabel(recordedAt),
            valueColor: Theme.of(context).colorScheme.primary,
            icon: Icons.schedule_outlined,
            tooltip: '用时钟挑选时刻',
            onTap: () => onPickTime(context),
          ),
        ],
      ),
    );
  }

  /// 一行入口：左标签、中间当前值、行尾图形化按钮。
  ///
  /// 值整组包在 `FittedBox(scaleDown)` 里：中文长日期在窄屏上宁可等比缩一点点，
  /// 也不折成两行 —— 一折行，这一行「值 + 按钮」的对应关系就散了。
  Widget _entry(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? valueColor,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    // 等宽数字：值会随选择器变化，字宽不跳才不会左右抖
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                    color: valueColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _PickerButton(icon: icon, tooltip: tooltip, onTap: onTap),
          ],
        ),
      ),
    );
  }
}

class _TitleField extends StatefulWidget {
  const _TitleField({required this.state, required this.controller});

  final EditRecordState state;
  final EditRecordController controller;

  @override
  State<_TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<_TitleField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.state.title);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      onChanged: widget.controller.setTitle,
      textInputAction: TextInputAction.next,
      // 不写 border：填充色 + 16 圆角 + 聚焦主色描边都来自主题，
      // 之前这里写死的 `OutlineInputBorder()` 是框架默认的 4 圆角。
      decoration: const InputDecoration(
        labelText: '标题（选填）',
        hintText: '给这条记录起个名字',
        prefixIcon: Icon(Icons.title_outlined),
      ),
    );
  }
}

/// 内容输入：独立成 StatefulWidget 以持有自己的 TextEditingController，
/// 避免在每次 rebuild 时重建 controller 导致光标跳位。
class _ContentField extends StatefulWidget {
  const _ContentField({required this.state, required this.controller});

  final EditRecordState state;
  final EditRecordController controller;

  @override
  State<_ContentField> createState() => _ContentFieldState();
}

class _ContentFieldState extends State<_ContentField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.state.content);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      onChanged: widget.controller.setContent,
      autofocus: widget.state.isNew,
      keyboardType: TextInputType.multiline,
      minLines: 5,
      maxLines: 12,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: '内容（必填）',
        hintText: '记下这一刻…',
        alignLabelWithHint: true,
        // 原来这里还有一句 helperText「必填」—— label 已经写了「（必填）」，
        // 同一句提示在上下两处重复，底栏只留右下角的字数统计。
        counter: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, value, _) => Text('${value.text.length} 字'),
        ),
      ),
    );
  }
}

class _TagsSection extends StatelessWidget {
  const _TagsSection({required this.state, required this.controller});

  final EditRecordState state;
  final EditRecordController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    // 包进卡片：标签原来是裸在页面底上的一行，上下都是白卡/白输入框，
    // 只有它直接贴着背景 —— 整页的区块节奏在它这里断掉。
    return Card(
      color: surfaces.card,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '标签',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${state.tags.length} 个',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ...state.tags.map(
                  (tag) => Chip(
                    label: Text('#$tag'),
                    onDeleted: () => controller.removeTag(tag),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    backgroundColor: scheme.secondaryContainer,
                    side: BorderSide.none,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('添加标签'),
                  onPressed: () => _promptNewTag(context),
                ),
              ],
            ),
            // 历史标签：以前用过的直接点一下加入，不用重敲一遍
            _HistoryTagSuggestions(
              currentTags: state.tags,
              onPick: controller.addTag,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptNewTag(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _TagInputDialog(currentTags: state.tags),
    );
    if (text != null) controller.addTag(text);
  }
}

/// 历史标签建议：把「以前用过的标签」摆在手边，点一下直接加进本条记录。
///
/// 数据源与首页过滤栏同一份（`tagCountsProvider`，条数降序）——
/// 全站「有哪些标签、各多少条」只有这一个口径。
/// 已经在本条记录上的标签不再出现；最多摆 [_maxShown] 个：
/// 再多就属于「找」而不是「挑」的场景了，交给添加框里的过滤建议。
class _HistoryTagSuggestions extends ConsumerWidget {
  const _HistoryTagSuggestions({
    required this.currentTags,
    required this.onPick,
  });

  final List<String> currentTags;
  final ValueChanged<String> onPick;

  static const int _maxShown = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);
    final suggestions = ref
        .watch(tagCountsProvider)
        .where((t) => !currentTags.contains(t.tag))
        .take(_maxShown)
        .toList();
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '历史标签 · 点一下加入',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final t in suggestions)
                ActionChip(
                  avatar: Icon(
                    Icons.add,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  label: Text('#${t.tag}'),
                  onPressed: () => onPick(t.tag),
                  // 凹槽底 + 弱文字：与已添加的（secondaryContainer 实色）
                  // 拉开「建议」与「已生效」两档，不会误以为已经加上了。
                  backgroundColor: surfaces.inset,
                  side: BorderSide(color: surfaces.border),
                  labelStyle: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 添加标签对话框：上半是新标签输入，下半是**随输入过滤**的历史标签建议。
///
/// 建议区两个用处：一是少打字（点一下就选中）；二是防重 ——
/// 想敲「咖啡馆」时发现「咖啡」已经存在，就不会再养出一个近义标签。
/// 输入为空时显示最常用的 [_maxSuggestions] 个；有输入时按包含关系过滤。
class _TagInputDialog extends ConsumerStatefulWidget {
  const _TagInputDialog({required this.currentTags});

  /// 本条记录已有的标签（不再出现在建议里）。
  final List<String> currentTags;

  @override
  ConsumerState<_TagInputDialog> createState() => _TagInputDialogState();
}

class _TagInputDialogState extends ConsumerState<_TagInputDialog> {
  final TextEditingController _controller = TextEditingController();

  static const int _maxSuggestions = 6;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _controller.text.trim().toLowerCase();
    final suggestions = ref
        .watch(tagCountsProvider)
        .where((t) => !widget.currentTags.contains(t.tag))
        .where((t) => query.isEmpty || t.tag.toLowerCase().contains(query))
        .take(_maxSuggestions)
        .toList();

    void submit([String? value]) =>
        Navigator.of(context).pop(value ?? _controller.text);

    return AlertDialog(
      title: const Text('添加标签'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            // 输入变化 → 建议区跟着过滤
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => submit(),
            decoration: const InputDecoration(
              labelText: '标签名称',
              hintText: '例如：运动、读书',
            ),
          ),
          if (suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              query.isEmpty ? '历史标签' : '匹配的历史标签',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final t in suggestions)
                  ActionChip(
                    label: Text('#${t.tag}'),
                    onPressed: () => submit(t.tag),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: () => submit(), child: const Text('添加')),
      ],
    );
  }
}

/// 只读元信息：让「业务日期 / 入库时间 / 最后修改」三者一目了然。
class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.state});

  final EditRecordState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: VestigeRadius.mediumAll,
        border: Border.all(color: surfaces.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '元信息',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          _MetaRow(
            label: '记录日期',
            value: '${dayKey(state.recordedAt)} ${timeLabel(state.recordedAt)}',
            editable: true,
          ),
          _MetaRow(
            label: '入库时间',
            value: state.createdAt == null
                ? '—'
                : dateTimeLabel(state.createdAt!),
            note: '只读，用于识别补记',
          ),
          _MetaRow(
            label: '最后修改',
            value: state.updatedAt == null
                ? '—'
                : dateTimeLabel(state.updatedAt!),
          ),
          _MetaRow(label: 'ID', value: state.id, selectable: true),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.label,
    required this.value,
    this.note,
    this.editable = false,
    this.selectable = false,
  });

  final String label;
  final String value;
  final String? note;
  final bool editable;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(label, style: style),
          ),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(
                    note == null ? value : '$value  ·  $note',
                    style: editable
                        ? style?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : style,
                  ),
          ),
        ],
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = VestigeTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        // 实色（不再是 50% 半透明）：半透明的琥珀叠在页面底上会发灰，
        // 「补记」这个语义色一旦被冲淡就读不出来了。
        color: tokens.backfillContainer,
        borderRadius: VestigeRadius.mediumAll,
        border: Border.all(
          color: tokens.backfill.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: tokens.onBackfillContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: tokens.onBackfillContainer,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.onBackfillContainer,
                    height: 1.5,
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
