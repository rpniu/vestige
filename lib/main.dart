import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/app/router.dart';
import 'package:vestige/app/theme.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

/// 入口：预读 SharedPreferences → ProviderScope 注入 → MaterialApp.router。
///
/// 先 await SharedPreferences 再 runApp，是为了让主题偏好在首帧就生效，
/// 避免冷启动时先渲染默认配色再跳变。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const VestigeApp(),
    ),
  );
}

class VestigeApp extends ConsumerWidget {
  const VestigeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(themeProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Vestige',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: buildVestigeTheme(settings.variant, Brightness.light),
      darkTheme: buildVestigeTheme(settings.variant, Brightness.dark),
      themeMode: settings.mode,
      // 中文本地化：日期/时间选择器、选择菜单等系统组件跟着中文显示
      locale: const Locale('zh', 'CN'),
      // 只声明 zh_CN —— 本 App 的界面文案是硬编码中文，没有接 AppLocalizations，
      // 所以没有任何「英文界面」可言。声明 en_US 等于对外声称支持英文而实际做不到。
      // 若将来真要支持多语言，再引入 AppLocalizations 并把 en_US 加回来。
      supportedLocales: const <Locale>[Locale('zh', 'CN')],
      // 这三个 delegate 与「App 自身文案的 i18n」是两件事：它们提供的是
      // Material / Cupertino **内置组件**的中文（日期选择器的月份名与「确定/取消」、
      // 时钟的「上午/下午」、长按文本的「复制/粘贴」菜单）。**不因未接入 i18n 而移除**，
      // 移除后编辑页的日历/时钟弹层会变英文（`edit_time_panel_test` 的断言会直接失败）。
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
