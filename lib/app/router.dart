import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/domain/day_util.dart';
import 'package:vestige/presentation/screens/edit_screen.dart';
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
  static String editNew({DateTime? day}) =>
      day == null ? edit : '$edit?day=${dayKey(day)}';

  static String editExisting(String id) => '$edit/$id';
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
          ),
          routes: <RouteBase>[
            GoRoute(
              path: ':id',
              builder: (context, state) => EditScreen(
                recordId: state.pathParameters['id'],
              ),
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

class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final surfaces = VestigeSurfaces.of(context);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: surfaces.card,
          border: Border(
            top: BorderSide(
              color: surfaces.border,
              width: 0.8,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) => navigationShell.goBranch(
            index,
            // 再次点击当前 tab 时回到该分支的初始页面
            initialLocation: index == navigationShell.currentIndex,
          ),
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
