// 搜索历史的规则单测：去重、提到最前、截断、单删、清空，以及是否真的落盘。
//
// 这些规则刻意放在 provider 里而不是页面里，就是为了能这样直接对着
// ProviderContainer 测 —— 不用起 widget，跑得快，失败信息也准。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/presentation/providers/search_history_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

void main() {
  late ProviderContainer container;
  late SharedPreferences prefs;

  /// 备一份内存版偏好并起一个容器（搜索历史的 provider 默认会抛，必须 override）。
  Future<void> boot({List<String> initial = const <String>[]}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (initial.isNotEmpty) 'search_history': initial,
    });
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
  }

  SearchHistoryController ctrl() =>
      container.read(searchHistoryProvider.notifier);

  List<String> history() => container.read(searchHistoryProvider);

  test('初始为空', () async {
    await boot();
    expect(history(), isEmpty);
  });

  test('remember 把词放到最前', () async {
    await boot();
    ctrl().remember('咖啡');
    ctrl().remember('水洗');
    expect(history(), <String>['水洗', '咖啡']);
  });

  test('同一个词再搜一次：提到最前，不留重复项', () async {
    await boot();
    ctrl().remember('咖啡');
    ctrl().remember('水洗');
    ctrl().remember('咖啡');
    expect(history(), <String>['咖啡', '水洗']);
  });

  test('首尾空白会被 trim；纯空白不记', () async {
    await boot();
    ctrl().remember('  咖啡  ');
    ctrl().remember('   ');
    expect(history(), <String>['咖啡']);
  });

  test('超过上限时丢掉最旧的', () async {
    await boot();
    for (var i = 0; i < SearchHistoryController.maxEntries + 3; i++) {
      ctrl().remember('q$i');
    }
    final list = history();
    expect(list.length, SearchHistoryController.maxEntries);
    expect(list.first, 'q${SearchHistoryController.maxEntries + 2}');
    expect(list.contains('q0'), isFalse, reason: '最旧的被挤掉了');
  });

  test('remove 只删那一条；clear 全清', () async {
    await boot();
    ctrl()
      ..remember('咖啡')
      ..remember('水洗');

    ctrl().remove('咖啡');
    expect(history(), <String>['水洗']);

    ctrl().clear();
    expect(history(), isEmpty);
  });

  test('写盘了：换个容器重新读还在（等价于一次冷启动）', () async {
    await boot();
    ctrl().remember('咖啡');

    final restarted = ProviderContainer(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(restarted.dispose);

    expect(restarted.read(searchHistoryProvider), <String>['咖啡']);
  });
}
