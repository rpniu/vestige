import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「主页图标回顶 + 刷新」的请求计数。
///
/// 底部导航（router 的 `_ShellScaffold`）在**再次点击当前的主页 tab** 时
/// 把计数 +1；HomeScreen 监听它执行「滚回顶部 + 重订阅数据流」。
/// 用计数而不是布尔：连续点两次也能触发两次，不会漏。
final homeTopRequestProvider = StateProvider<int>((ref) => 0);
