import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/presentation/providers/theme_provider.dart'
    show sharedPreferencesProvider;

/// 搜索历史：最近搜过的关键词，用 shared_preferences 持久化。
///
/// 只记**已经执行过的搜索**，不记「敲了一半」的中间态 ——
/// 否则每敲一个字符都会往历史里塞一条，列表会被 `咖`、`咖啡` 这种碎片塞满。
///
/// 同一个词再搜一次是**提到最前**，不是留两条：历史列表的价值在于「最近找过什么」，
/// 重复项只会挤掉其他词条。
class SearchHistoryController extends Notifier<List<String>> {
  static const String _key = 'search_history';

  /// 最多留多少条。再多就不能一眼扫完了，而这是个「顺手回看」的功能，
  /// 不是可检索的档案。
  static const int maxEntries = 10;

  @override
  List<String> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getStringList(_key) ?? const <String>[];
  }

  /// 记一条：去重 → 提到最前 → 截断到 [maxEntries]。
  void remember(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final next = <String>[
      q,
      ...state.where((String e) => e != q),
    ];
    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    _write(next);
  }

  /// 删掉某一条（历史 chip 上的小叉）。
  void remove(String query) =>
      _write(state.where((String e) => e != query).toList(growable: false));

  /// 清空全部。
  void clear() => _write(const <String>[]);

  void _write(List<String> next) {
    state = next;
    // 与主题偏好同款：不 await —— 写失败最多丢一次历史，不值得让 UI 等它。
    ref.read(sharedPreferencesProvider).setStringList(_key, next);
  }
}

final searchHistoryProvider =
    NotifierProvider<SearchHistoryController, List<String>>(
  SearchHistoryController.new,
);
