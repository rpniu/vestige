import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题偏好：配色方案 + 明暗模式，用 shared_preferences 持久化
/// （对应原 Kotlin 的 ThemeManager）。
///
/// SharedPreferences 实例在 main() 里先 await 出来，再通过 override 注入，
/// 这样读取偏好是同步的，冷启动不会先闪一下默认主题。

/// 在 main() 中用 `sharedPreferencesProvider.overrideWithValue(prefs)` 覆盖。
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider 必须在 main() 中 override'),
);

/// 配色方案。原 Kotlin 只有这两种。
enum AppThemeVariant {
  defaultBlue('默认蓝色', '经典蓝 · 干净利落'),
  sageGreen('鼠尾草绿', '低饱和绿 · 护眼耐看');

  const AppThemeVariant(this.title, this.description);

  final String title;
  final String description;
}

/// 主题设置。
@immutable
class ThemeSettings {
  const ThemeSettings({
    this.variant = AppThemeVariant.defaultBlue,
    this.mode = ThemeMode.system,
  });

  final AppThemeVariant variant;
  final ThemeMode mode;

  ThemeSettings copyWith({AppThemeVariant? variant, ThemeMode? mode}) =>
      ThemeSettings(
        variant: variant ?? this.variant,
        mode: mode ?? this.mode,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemeSettings && other.variant == variant && other.mode == mode;

  @override
  int get hashCode => Object.hash(variant, mode);
}

final themeProvider = NotifierProvider<ThemeController, ThemeSettings>(
  ThemeController.new,
);

class ThemeController extends Notifier<ThemeSettings> {
  static const String _keyVariant = 'app_theme_variant';
  static const String _keyMode = 'app_theme_mode';

  @override
  ThemeSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return ThemeSettings(
      variant: _variantFrom(prefs.getString(_keyVariant)),
      mode: _modeFrom(prefs.getString(_keyMode)),
    );
  }

  void setVariant(AppThemeVariant variant) {
    state = state.copyWith(variant: variant);
    ref.read(sharedPreferencesProvider).setString(_keyVariant, variant.name);
  }

  void setMode(ThemeMode mode) {
    state = state.copyWith(mode: mode);
    ref.read(sharedPreferencesProvider).setString(_keyMode, mode.name);
  }

  /// 在 跟随系统 → 浅色 → 深色 之间循环（顶栏快捷按钮用）。
  void cycleMode(Brightness platformBrightness) {
    final effective = switch (state.mode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
    setMode(effective == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
  }

  static AppThemeVariant _variantFrom(String? name) {
    for (final v in AppThemeVariant.values) {
      if (v.name == name) return v;
    }
    return AppThemeVariant.defaultBlue;
  }

  static ThemeMode _modeFrom(String? name) {
    for (final m in ThemeMode.values) {
      if (m.name == name) return m;
    }
    return ThemeMode.system;
  }
}

/// 给 UI 用的展示名。
String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };
