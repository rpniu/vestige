import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/providers/core_providers.dart';

/// 编辑页状态。
///
/// 关键点：**业务日期 recordedAt 与入库时间 createdAt 是两个独立字段**。
/// - 新建时 recordedAt 默认「现在」，可以随意改成过去的某天（这就是补记）；
/// - createdAt 在生产代码里只读，只在 CSV 导入时才会被显式写入；
/// - 保存既有记录时不碰 createdAt，审计信息不会被编辑动作污染。

/// `recordId` 为 `new` 时表示新建。
const String kNewRecordId = 'new';

/// 新建时可以把「预置的业务日期」和「预置时长」编码进 family 参数：
/// `new@2026-09-14` 表示新建一条归属于 9 月 14 日的记录（补记入口）；
/// `new@@2700` 只带时长（首页计时器「停止并记录」：日期就是今天，不需要预置）。
///
/// 格式固定为 `new@<日期>@<秒>` 两段，**空段保留**（连续两个 `@`）——
/// 早先的实现只在有日期时才写时长段，结果计时器入口（无日期）把时长整段丢了。
String editRecordKey({
  String? recordId,
  DateTime? initialDay,
  int? initialDurationSec,
}) {
  if (recordId != null) return recordId;
  if (initialDay == null && initialDurationSec == null) return kNewRecordId;
  final day = initialDay == null ? '' : dayKey(initialDay);
  final dur = initialDurationSec == null ? '' : '$initialDurationSec';
  return '$kNewRecordId@$day@$dur';
}

/// 解析 `new@yyyy-MM-dd[@dur]` 里的日期段：保留当前时刻，只换日期 ——
/// 免得补记出来的记录一律显示 00:00。日期段后面可能还跟着时长段。
DateTime? seededRecordedAt(String key) {
  final at = key.indexOf('@');
  if (at < 0) return null;
  final rest = key.substring(at + 1);
  final next = rest.indexOf('@');
  final day = DateTime.tryParse(next < 0 ? rest : rest.substring(0, next));
  if (day == null) return null;
  final now = DateTime.now();
  return DateTime(day.year, day.month, day.day, now.hour, now.minute, now.second);
}

/// 解析 key 第 3 段（`new@day@dur` 里的 dur，**秒**），不是合法正整数就当没给。
int? seededDurationSec(String key) {
  final first = key.indexOf('@');
  if (first < 0) return null;
  final second = key.indexOf('@', first + 1);
  if (second < 0) return null;
  final value = int.tryParse(key.substring(second + 1));
  return value == null || value <= 0 ? null : value;
}

/// 按 family key 构造「新建」的初始状态。
///
/// provider 与页面**共用这一份**：provider 拿到的是权威状态（保存与改字段都走它），
/// 页面在 provider 的异步值到达之前先用这里的结果渲染首帧 —— 新建记录没有任何
/// IO，不该先闪一帧转圈。
/// 两边各自生成 UUID，所以 id 不同；但保存落库用的是 controller 的 state，
/// 页面这份临时 id 不会被写入。
EditRecordState newRecordStateFromKey(String key) => EditRecordState.newRecord(
      id: const Uuid().v4(),
      recordedAt: seededRecordedAt(key),
      durationSec: seededDurationSec(key),
    );

final editRecordProvider =
    AsyncNotifierProvider.autoDispose.family<EditRecordController, EditRecordState, String>(
  EditRecordController.new,
);

class EditRecordController
    extends AutoDisposeFamilyAsyncNotifier<EditRecordState, String> {
  static const Uuid _uuid = Uuid();

  @override
  Future<EditRecordState> build(String arg) async {
    if (arg == kNewRecordId || arg.startsWith('$kNewRecordId@')) {
      return newRecordStateFromKey(arg);
    }
    final record = await ref.read(recordRepositoryProvider).getRecordById(arg);
    if (record == null) {
      // 记录可能已在其他位置被彻底删除：退回成一个新记录，避免白屏。
      return EditRecordState.newRecord(id: _uuid.v4());
    }
    return EditRecordState.fromEntity(record);
  }

  EditRecordState get _current =>
      state.valueOrNull ?? EditRecordState.newRecord(id: _uuid.v4());

  /// 最近一次失败的说明（没有错时为 null）。
  ///
  /// 给页面用：`save()` 只回 bool，「失败」既可能是内容为空、也可能是写库异常，
  /// 页面需要能读到具体原因才不会一律提示「内容不能为空」（审查 M-002）。
  /// 这里转出而不是让页面直接读 `state` —— `AsyncNotifier.state` 是受保护成员，
  /// 外部访问会被 lint 拦下（invalid_use_of_protected_member）。
  String? get lastError => state.valueOrNull?.error;

  void _update(EditRecordState Function(EditRecordState s) transform) {
    state = AsyncData(transform(_current));
  }

  void setTitle(String value) => _update((s) => s.copyWith(title: value));

  void setContent(String value) => _update((s) => s.copyWith(content: value));

  void addTag(String raw) {
    final tag = raw.trim();
    if (tag.isEmpty) return;
    _update((s) {
      if (s.tags.contains(tag)) return s;
      return s.copyWith(tags: [...s.tags, tag]);
    });
  }

  void removeTag(String tag) =>
      _update((s) => s.copyWith(tags: s.tags.where((t) => t != tag).toList()));

  /// 改业务日期：**保留当前时刻**，只换年月日。
  /// 补记「8 月 1 日」时，时间部分仍是 11:14 而不是 00:00，列表里看着自然。
  void setRecordedDay(DateTime day) {
    final cur = _current.recordedAt;
    _update(
      (s) => s.copyWith(
        recordedAt: DateTime(
          day.year,
          day.month,
          day.day,
          cur.hour,
          cur.minute,
          cur.second,
        ),
      ),
    );
  }

  /// 只改时刻，保留日期。
  void setRecordedTime(int hour, int minute) {
    final cur = _current.recordedAt;
    _update(
      (s) => s.copyWith(
        recordedAt: DateTime(
          cur.year,
          cur.month,
          cur.day,
          hour,
          minute,
          cur.second,
        ),
      ),
    );
  }

  /// 日期 + 时刻一起设（键盘输入把年月日时分合并后的结果）。
  /// 单独提供一个「一次成型」的 setter，避免日期与时刻分别写导致互相覆盖。
  void setRecordedDateTime(DateTime value) => _update(
        (s) => s.copyWith(
          recordedAt: DateTime(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
            s.recordedAt.second,
          ),
        ),
      );

  /// 日期整体平移 [deltaDays] 天（昨天/明天 快捷按钮）。
  void shiftRecordedDay(int deltaDays) {
    final cur = _current.recordedAt;
    _update(
      (s) => s.copyWith(
        recordedAt: DateTime(
          cur.year,
          cur.month,
          cur.day + deltaDays,
          cur.hour,
          cur.minute,
          cur.second,
        ),
      ),
    );
  }

  /// 回到「现在」。
  void resetToNow() =>
      _update((s) => s.copyWith(recordedAt: DateTime.now(), isSaving: s.isSaving));

  /// 「补交」入口：把业务日期挪到昨天。
  ///
  /// 已经是过去日期的话保持不动 —— 用户可能已经挑好了更早的某天，
  /// 不该被这个开关重置。之后再让他用「前天 / 上周今天 / 选日期」微调。
  void startBackfill() {
    if (!_current.isRecordedToday) return;
    shiftRecordedDay(-1);
  }

  /// 设置时长（**秒**）。0 或负数视同清空。
  void setDurationSec(int? seconds) => _update((s) {
        if (seconds == null || seconds <= 0) {
          return s.copyWith(clearDuration: true);
        }
        return s.copyWith(durationSec: seconds);
      });

  /// 保存。成功返回 true。
  Future<bool> save() async {
    final s = _current;
    if (!s.canSave) return false;

    _update((c) => c.copyWith(isSaving: true, clearError: true));
    final repo = ref.read(recordRepositoryProvider);
    final content = s.content.trim();
    final title = s.title.trim();

    try {
      if (s.isNew) {
        await repo.addRecord(
          id: s.id,
          content: content,
          title: title,
          tags: s.tags,
          recordedAt: s.recordedAt,
          durationSec: s.durationSec,
        );
        // 落库后 createdAt 就是「现在」，同步回状态以便立刻显示补记标记。
        // `originalDurationSec` 一起对齐到已落库的值：它记的是「库里现在是什么」，
        // 不刷新的话，之后再清空时长会被判成「本来就没有」，写库时被当成不动。
        final now = DateTime.now();
        _update(
          (c) => c.copyWith(
            isNew: false,
            isSaving: false,
            createdAt: now,
            updatedAt: now,
            originalDurationSec: c.durationSec,
            overrideOriginalDuration: true,
          ),
        );
      } else {
        // 时长三态：改了 → 写新值；原来有、现在删了 → 清空；没动 → 不碰那一列。
        final hadDuration = s.originalDurationSec != null;
        await repo.updateRecord(
          id: s.id,
          content: content,
          title: title,
          tags: s.tags,
          recordedAt: s.recordedAt,
          durationSec: s.durationSec,
          clearDuration: s.durationSec == null && hadDuration,
        );
        _update(
          (c) => c.copyWith(
            isSaving: false,
            updatedAt: DateTime.now(),
            // 同上：已落库的时长成为新的「原值」，否则「设时长 → 保存 → 清空 → 保存」
            // 第二轮会把清空判成空操作，界面显示没时长、库里还留着旧值。
            originalDurationSec: c.durationSec,
            overrideOriginalDuration: true,
          ),
        );
      }
      return true;
    } catch (e) {
      _update((c) => c.copyWith(isSaving: false, error: '保存失败：$e'));
      return false;
    }
  }

  /// 软删除（进回收站）。成功返回 true。
  Future<bool> delete() async {
    if (_current.isNew) return true;
    try {
      await ref.read(recordRepositoryProvider).deleteRecord(_current.id);
      return true;
    } catch (e) {
      _update((c) => c.copyWith(error: '删除失败：$e'));
      return false;
    }
  }
}

/// 编辑页的不可变状态。
class EditRecordState {
  const EditRecordState({
    required this.id,
    required this.isNew,
    this.title = '',
    this.content = '',
    this.tags = const <String>[],
    required this.recordedAt,
    this.createdAt,
    this.updatedAt,
    this.isSaving = false,
    this.error,
    this.durationSec,
    this.originalDurationSec,
  });

  factory EditRecordState.newRecord({
    required String id,
    DateTime? recordedAt,
    int? durationSec,
  }) =>
      EditRecordState(
        id: id,
        isNew: true,
        recordedAt: recordedAt ?? DateTime.now(),
        durationSec: durationSec,
        originalDurationSec: durationSec,
      );

  factory EditRecordState.fromEntity(RecordEntity r) => EditRecordState(
        id: r.id,
        isNew: false,
        title: r.title ?? '',
        content: r.content,
        tags: r.tags,
        recordedAt: r.recordedAt,
        createdAt: r.createdAt,
        updatedAt: r.updatedAt,
        durationSec: r.durationS,
        originalDurationSec: r.durationS,
      );

  final String id;

  /// 是否尚未落库。
  final bool isNew;

  final String title;
  final String content;
  final List<String> tags;

  /// 业务日期（可改、可补记）。
  final DateTime recordedAt;

  /// 入库时间（只读；编辑既有记录时不变）。
  final DateTime? createdAt;

  final DateTime? updatedAt;
  final bool isSaving;
  final String? error;

  /// 本次记录的时长（**秒**），null = 没记。
  final int? durationSec;

  /// 打开编辑页时的时长原值 —— 用于保存时区分「用户清空了时长」和
  /// 「时长本来就没有」，后者不该被写库。
  final int? originalDurationSec;

  /// 相对今天隔了几天：0=今天，1=昨天，-1=明天…
  int get dayOffsetFromToday => dayDiff(recordedAt, DateTime.now());

  /// 是否为「补记」（归属日 ≠ 入库日）。
  bool get isBackfilled {
    final created = createdAt;
    if (created == null) return false;
    return !isSameDay(recordedAt, created);
  }

  /// 补记延迟天数（非补记返回 0）。
  int get backfillDelayDays {
    final created = createdAt;
    if (created == null || !isBackfilled) return 0;
    return dayDiff(recordedAt, created);
  }

  bool get isRecordedToday => isSameDay(recordedAt, DateTime.now());

  bool get canSave => content.trim().isNotEmpty && !isSaving;

  EditRecordState copyWith({
    String? id,
    bool? isNew,
    String? title,
    String? content,
    List<String>? tags,
    DateTime? recordedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isSaving,
    String? error,
    bool clearError = false,
    int? durationSec,
    bool clearDuration = false,
    int? originalDurationSec,
    bool overrideOriginalDuration = false,
  }) =>
      EditRecordState(
        id: id ?? this.id,
        isNew: isNew ?? this.isNew,
        title: title ?? this.title,
        content: content ?? this.content,
        tags: tags ?? this.tags,
        recordedAt: recordedAt ?? this.recordedAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        isSaving: isSaving ?? this.isSaving,
        error: clearError ? null : (error ?? this.error),
        durationSec:
            clearDuration ? null : (durationSec ?? this.durationSec),
        // 「原值」必须能被显式改成 null（清空时长后它就该是 null），
        // 所以不能只靠 `?? this.x` —— 那样 null 会被当成「没传」而保留旧值。
        originalDurationSec: overrideOriginalDuration
            ? originalDurationSec
            : this.originalDurationSec,
      );
}
