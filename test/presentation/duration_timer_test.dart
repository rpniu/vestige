// 计时器 provider 的单元测试（纯逻辑，不依赖 Widget 环境）。
//
// 覆盖的是「口径」这类最容易悄悄漂移的东西：
// - 结算的下限（1 秒）与上界（24 小时），确认框展示与落库共用同一份；
// - start / stop / cancel 对状态与存储的收尾；
// - 恢复时丢掉两类脏数据：起点在未来（时钟回拨）、起点超过 24 小时。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/presentation/providers/duration_timer_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

const String _prefsKey = 'duration_timer_start_ms';

/// 内存版 prefs，但 `remove` 故意慢 100ms（模拟真机的平台通道往返）。
///
/// 用来复现「停止后立刻重新开始」的写盘乱序：不排队的话，慢的 remove 会落在
/// 新的 setInt 之后，把起点抹掉。
class _SlowRemovePrefs implements SharedPreferences {
  final Map<String, Object> _store = <String, Object>{};

  @override
  int? getInt(String key) => _store[key] as int?;

  @override
  Future<bool> setInt(String key, int value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _store.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 用给定的初始偏好值起一个容器（模拟「杀进程后重新打开」也走这里）。
Future<(ProviderContainer, SharedPreferences)> _boot(
  Map<String, Object> initial,
) async {
  SharedPreferences.setMockInitialValues(initial);
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return (container, prefs);
}

void main() {
  group('clampSessionSeconds · 结算口径', () {
    test('不足 1 秒按 1 秒记，负值同样按 1 秒', () {
      expect(clampSessionSeconds(Duration.zero), 1);
      expect(clampSessionSeconds(const Duration(seconds: -30)), 1);
    });

    test('超过 24 小时按上界记', () {
      expect(
        clampSessionSeconds(const Duration(hours: 30)),
        DurationTimerNotifier.maxSessionDuration.inSeconds,
      );
    });

    test('区间内的值原样返回', () {
      expect(clampSessionSeconds(const Duration(minutes: 90)), 5400);
    });
  });

  group('DurationTimerNotifier', () {
    test('start 记下记录本并写入起点；stop 结算后清空状态与存储', () async {
      final (ProviderContainer container, SharedPreferences prefs) = await _boot(
        <String, Object>{},
      );
      final DurationTimerNotifier notifier = container.read(
        durationTimerProvider.notifier,
      );

      expect(notifier.peekElapsedSeconds(), 0);
      await notifier.start(bookId: 'book-a');
      expect(notifier.startedBookId, 'book-a');
      expect(container.read(durationTimerProvider), isNotNull);
      expect(prefs.getInt(_prefsKey), isNotNull);
      // 刚开就结算：不足 1 秒，按下限记 1 秒。
      expect(notifier.peekElapsedSeconds(), 1);

      expect(await notifier.stop(), 1);
      expect(container.read(durationTimerProvider), isNull);
      expect(notifier.startedBookId, isNull);
      expect(prefs.getInt(_prefsKey), isNull);
    });

    test('cancel 不结算，但同样清空状态与存储', () async {
      final (ProviderContainer container, SharedPreferences prefs) = await _boot(
        <String, Object>{},
      );
      final DurationTimerNotifier notifier = container.read(
        durationTimerProvider.notifier,
      );
      await notifier.start(bookId: 'book-a');

      await notifier.cancel();
      expect(container.read(durationTimerProvider), isNull);
      expect(notifier.startedBookId, isNull);
      expect(prefs.getInt(_prefsKey), isNull);
    });

    test('恢复：起点在未来的脏数据直接丢弃', () async {
      final int future = DateTime.now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      final (ProviderContainer container, _) = await _boot(<String, Object>{
        _prefsKey: future,
      });

      expect(container.read(durationTimerProvider), isNull);
    });

    test('恢复：超过 24 小时的起点丢弃，并顺手清掉存储', () async {
      final int stale = DateTime.now()
          .subtract(const Duration(hours: 30))
          .millisecondsSinceEpoch;
      final (ProviderContainer container, SharedPreferences prefs) = await _boot(
        <String, Object>{_prefsKey: stale},
      );

      expect(container.read(durationTimerProvider), isNull);
      // 清理是写完即忘的，等一个微任务让它落地。
      await Future<void>.delayed(Duration.zero);
      expect(prefs.getInt(_prefsKey), isNull);
    });

    test('停止后立刻重新开始：新起点不会被上一次的 remove 抹掉', () async {
      final _SlowRemovePrefs prefs = _SlowRemovePrefs();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      final DurationTimerNotifier notifier = container.read(
        durationTimerProvider.notifier,
      );

      await notifier.start(bookId: 'book-a');
      expect(prefs.getInt(_prefsKey), isNotNull);

      // 停止（清理被甩到后台），紧接着重新开始 —— 写盘顺序必须仍然确定。
      unawaited(notifier.stop());
      await notifier.start(bookId: 'book-b');

      // 等两条写盘都落地。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        prefs.getInt(_prefsKey),
        isNotNull,
        reason: '新的起点不能被上一次停止的 remove 抹掉（否则重启后计时消失）',
      );
      expect(notifier.startedBookId, 'book-b');
    });

    test('恢复：正常起点原样恢复', () async {
      final int past = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      final (ProviderContainer container, _) = await _boot(<String, Object>{
        _prefsKey: past,
      });

      final DateTime? startedAt = container.read(durationTimerProvider);
      expect(startedAt, isNotNull);
      expect(container.read(durationTimerProvider.notifier).peekElapsedSeconds(),
          closeTo(600, 2));
      // 恢复而来的计时不知道原本属于哪本，不再参与跨本提示。
      expect(container.read(durationTimerProvider.notifier).startedBookId, isNull);
    });
  });
}
