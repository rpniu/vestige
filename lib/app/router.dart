import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/screens/edit_screen.dart';
import 'package:vestige/presentation/providers/home_scroll_provider.dart';
import 'package:vestige/presentation/screens/home_screen.dart';
import 'package:vestige/presentation/screens/profile_screen.dart';
import 'package:vestige/presentation/screens/search_screen.dart';
import 'package:vestige/presentation/screens/stats_screen.dart';
import 'package:vestige/presentation/screens/trash_screen.dart';
import 'package:vestige/presentation/screens/undo_history_screen.dart';

/// 路由表（go_router）。
///
/// 三个 tab（首页 / 统计 / 我的）用 `StatefulShellRoute.indexedStack` 承载，
/// 各自保留自己的导航栈与滚动位置；`/edit` 与 `/trash` 挂在根导航器上，
/// 以整页推入的方式盖住底部栏——和原 Compose 版 NavigationBar 的行为一致。
///
/// 补记入口：`/edit?day=2026-09-01` 打开新建页并预置业务日期。
abstract final class AppRoutes {
  static const String home = '/home';
  static const String stats = '/stats';
  static const String profile = '/profile';
  static const String trash = '/trash';
  static const String undoHistory = '/undo-history';
  static const String edit = '/edit';
  static const String search = '/search';

  /// 新建（默认今天）。传 [day] 则预置为该天 —— 这就是「补记」入口。
  /// 传 [durationSec] 则预置时长（**秒**）—— 首页计时器「停止并记录」的入口。
  static String editNew({DateTime? day, int? durationSec}) {
    final params = <String>[
      if (day != null) 'day=${dayKey(day)}',
      if (durationSec != null) 'dur=$durationSec',
    ];
    return params.isEmpty ? edit : '$edit?${params.join('&')}';
  }

  static String editExisting(String id) => '$edit/${Uri.encodeComponent(id)}';
}

final routerProvider = Provider<GoRouter>((ref) => createRouter());

GoRouter createRouter() => GoRouter(
  initialLocation: AppRoutes.home,
  debugLogDiagnostics: false,
  routes: <RouteBase>[
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _ShellScaffold(navigationShell: navigationShell),
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: AppRoutes.home,
              builder: (context, state) => const HomeScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: AppRoutes.stats,
              builder: (context, state) => const StatsScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            GoRoute(
              path: AppRoutes.profile,
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: AppRoutes.edit,
      builder: (context, state) => EditScreen(
        initialDay: _parseDay(state.uri.queryParameters['day']),
        initialDurationSec: int.tryParse(
          state.uri.queryParameters['dur'] ?? '',
        ),
      ),
      routes: <RouteBase>[
        GoRoute(
          path: ':id',
          builder: (context, state) =>
              EditScreen(recordId: _recordIdOf(state)),
        ),
      ],
    ),
    GoRoute(
      path: AppRoutes.trash,
      builder: (context, state) => const TrashScreen(),
    ),
    // 操作历史：从「我的」推入的整页（原先是一个居中弹层）。
    // 挂在根导航器上，整页盖住底部栏 —— 与回收站一致。
    GoRoute(
      path: AppRoutes.undoHistory,
      builder: (context, state) => const UndoHistoryScreen(),
    ),
    GoRoute(
      path: AppRoutes.search,
      builder: (context, state) => const SearchScreen(),
    ),
  ],
);

DateTime? _parseDay(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// 从 `/edit/<id>` 里取出记录 id。
///
/// 走 `state.uri.pathSegments`（`Uri` 按规范**解码一次**）而不是 `pathParameters`：
/// 写入侧是 [AppRoutes.editExisting] 的 `Uri.encodeComponent`，读取侧必须恰好解一次 ——
/// 编码没解会让含 `/`、空格、中文的 id 查不到库，解两次则会把 id 里本来就有的
/// `%` 序列改坏。两者都只在「特殊 id」上暴露，靠肉眼很难发现（2026-10-27 审查 M-004）。
String? _recordIdOf(GoRouterState state) {
  final segments = state.uri.pathSegments;
  return segments.length >= 2 ? segments.last : null;
}

class _ShellScaffold extends ConsumerWidget {
  const _ShellScaffold({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = VestigeSurfaces.of(context);
    return Scaffold(
      // 三个 tab 支持左右滑动切换：横向拖拽超过阈值（或带明显横向速度）时
      // 切到相邻分支。竖向滚动不受影响（检测器只认横向手势，
      // 子树的竖向 ListView 在手势竞技场里各认各的）。
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() < 120) return;
          final current = navigationShell.currentIndex;
          final next = velocity < 0 ? current + 1 : current - 1;
          if (next < 0 || next >= 3) return;
          HapticFeedback.selectionClick();
          navigationShell.goBranch(next);
        },
        child: navigationShell,
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: surfaces.card,
          border: Border(top: BorderSide(color: surfaces.border, width: 0.8)),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) {
            final alreadyCurrent = index == navigationShell.currentIndex;
            // 再次点击「主页」= 回到顶部并刷新一次数据（见
            // home_scroll_provider 的说明）。其余 tab 仍只做「回到初始页」。
            if (alreadyCurrent && index == 0) {
              ref.read(homeTopRequestProvider.notifier).state++;
            }
            navigationShell.goBranch(index, initialLocation: alreadyCurrent);
          },
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '主页',
            ),
            NavigationDestination(
              icon: Icon(Icons.insert_chart_outlined),
              selectedIcon: Icon(Icons.insert_chart_rounded),
              label: '统计',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
