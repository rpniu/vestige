import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

/// 首页计时器：记录「这次花了多久」的第二种录入方式。
///
/// 语义：**同一时间最多一个进行中的计时**（它对应的是「正在做的一件事」，
/// 不是计时器集合）。开始时刻存进 SharedPreferences —— 杀掉 App 再打开，
/// 计时还在走（时长按真实经过时间算，不暂停）。
///
/// 状态就是开始时刻（null = 没在计时）；经过多久由 UI 自己按需要算，
/// notifier 不跑秒级定时器 —— 计时是低频操作，不值得常驻一个 tick。
final durationTimerProvider =
    NotifierProvider<DurationTimerNotifier, DateTime?>(DurationTimerNotifier.new);

class DurationTimerNotifier extends Notifier<DateTime?> {
  static const String _prefsKey = 'duration_timer_start_ms';

  /// 单次计时的上界（24 小时）。
  ///
  /// 计时起点是持久化的（杀进程也照走），于是「开了计时忘了关、隔几天再打开」
  /// 会得到一个几百小时的时长：既不是真实投入，也会把编辑页的「时」轮与统计卡的
  /// 数字顶到很夸张的位置（2026-10-27 审查 M-003）。
  /// 超过上界一律按脏数据处理 —— 恢复时丢弃，结算时夹到上界。
  static const Duration maxSessionDuration = Duration(hours: 24);

  @override
  DateTime? build() {
    // prefs 拿不到时静默降级成「不持久化的内存计时」：计时是个锦上添花的
    // 偏好，不该因为存储不可用（如部分测试环境）把整页 build 炸掉。
    final SharedPreferences prefs;
    try {
      prefs = ref.watch(sharedPreferencesProvider);
    } catch (_) {
      return null;
    }
    final ms = prefs.getInt(_prefsKey);
    // 只在时长合理时恢复：时钟回拨/手工改存储到未来时刻的脏数据直接丢弃。
    if (ms == null || ms > DateTime.now().millisecondsSinceEpoch) return null;
    final startedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    if (DateTime.now().difference(startedAt) > maxSessionDuration) {
      // 超期同样当脏数据：顺手清掉存储（写完即忘 —— 清不掉也只是下次再清一次）。
      unawaited(_persist((prefs) => prefs.remove(_prefsKey)));
      return null;
    }
    return startedAt;
  }

  /// 开始计时（已在计时时幂等 —— 不重置起点）。
  Future<void> start() async {
    if (state != null) return;
    final now = DateTime.now();
    state = now;
    await _persist((prefs) => prefs.setInt(
          _prefsKey,
          now.millisecondsSinceEpoch,
        ));
  }

  /// 停止并结算：返回经过的**秒数**（至少 1 秒 —— 计了不到 1 秒也记 1 秒，
  /// 0 秒没有记录价值）。超过 [maxSessionDuration] 的按上界结算。
  /// 成功后计时结束、存储清空。
  Future<int> stop() async {
    final startedAt = state;
    if (startedAt == null) return 0;
    final elapsed = DateTime.now().difference(startedAt);
    state = null;
    await _persist((prefs) => prefs.remove(_prefsKey));
    final raw = elapsed.inSeconds < 1 ? 1 : elapsed.inSeconds;
    final max = maxSessionDuration.inSeconds;
    return raw > max ? max : raw;
  }

  /// 放弃本次计时（不结算）。
  Future<void> cancel() async {
    if (state == null) return;
    state = null;
    await _persist((prefs) => prefs.remove(_prefsKey));
  }

  /// 写存储。写不进去（存储不可用）就只留在内存里 —— 与 [build] 的降级一致。
  Future<void> _persist(Future<void> Function(SharedPreferences) action) async {
    try {
      await action(ref.read(sharedPreferencesProvider));
    } catch (_) {}
  }
}
