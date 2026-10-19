import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

/// 主题：flex_color_scheme 驱动 + 原 Kotlin `ui/theme/Color.kt` 配色 1:1 移植。
///
/// 没有用 flex_color_scheme 的内置预设（`FlexScheme.xxx`），而是把原 Compose
/// 工程里的每一个颜色常量都搬成 `ColorScheme` 再交给 FlexColorScheme 渲染。
/// 好处：视觉与旧版 App 完全一致，同时还能拿到 flex_color_scheme 的子主题
/// （统一圆角、圆角 AppBar 滚动、Chip 样式等）能力。
///
/// 两套配色：
/// - [AppThemeVariant.defaultBlue] 经典蓝（深蓝主色 + 暖黄点缀）
/// - [AppThemeVariant.sageGreen] 鼠尾草绿（低饱和绿 + 奶油底）

/// 圆角刻度（对应原 Kotlin `ui/theme/Shape.kt` 的「极大圆角」）。
///
/// 收敛成 5 档，页面里一律从这里取。之前仓里散着 4 / 6 / 10 / 16 / 18 / 24 / 32 / 999
/// 八种圆角，最刺眼的是编辑页：输入框用了框架默认的 4，紧挨着的日期卡是 24 ——
/// 一个页面像两个 App 拼起来的。现在按「元素越外层、圆角越大」排成一条刻度。
abstract final class VestigeRadius {
  /// 卡内小方块：时间徽标、面板里的小按钮、柱顶。
  static const double inset = 12;

  /// 输入框、按钮、chip、药丸按钮。
  static const double small = 16;

  /// 卡片。
  static const double medium = 24;

  /// 弹层 / 底部面板 / 对话框。
  static const double large = 32;

  /// 全圆：状态胶囊。
  static const double pill = 999;

  static final BorderRadius insetAll = BorderRadius.circular(inset);
  static final BorderRadius smallAll = BorderRadius.circular(small);
  static final BorderRadius mediumAll = BorderRadius.circular(medium);
  static final BorderRadius largeAll = BorderRadius.circular(large);
  static final BorderRadius pillAll = BorderRadius.circular(pill);
}

/// 四层表面 token —— 视觉层次的唯一来源。
///
/// ## 为什么需要它
/// 改版前每个页面都写 `scheme.surfaceContainerHighest.withValues(alpha: 0.35~0.5)`，
/// 叠出来的卡片色约 `#EEF1F7`，而页面底是 `#F8F9FF` —— 两者亮度差不到 3%，
/// 卡片只能靠一条 1px 的半透明描边证明自己存在。整屏因此糊成一片灰，
/// 深色模式下更糟（半透明浅灰叠在近黑底上，卡片发灰泥色）。
///
/// 现在改成**实色四层**，卡片与页面底拉开一档明度差，卡片真正「浮」起来：
///
/// | token | 角色 | 用在哪 |
/// |---|---|---|
/// | [base] | 页面底 | Scaffold 背景、AppBar 背景 |
/// | [card] | 容器面 | 卡片、底部导航栏 |
/// | [inset] | 卡内凹槽 | 时间徽标、数字格、输入框填充 |
/// | [border] | 容器描边 | 卡片边缘（很淡，只用来兜住轮廓） |
///
/// 新增颜色请加到这里，不要再在页面里写 `withValues(alpha: ...)` 调底色。
@immutable
class VestigeSurfaces extends ThemeExtension<VestigeSurfaces> {
  const VestigeSurfaces({
    required this.base,
    required this.card,
    required this.inset,
    required this.border,
    this.cardShadow = const <BoxShadow>[],
  });

  /// 页面底：比卡片深/暗一档，给卡片让出「浮起」的余地。
  final Color base;

  /// 容器面：卡片、底部导航栏。
  final Color card;

  /// 卡内凹槽：时间徽标底座、数字格、输入框填充。
  final Color inset;

  /// 容器描边。很淡 —— 层次靠明度差承担，描边只负责收边。
  final Color border;

  /// 卡片弥散阴影，营造悬浮感与呼吸感。
  final List<BoxShadow> cardShadow;

  static VestigeSurfaces of(BuildContext context) =>
      Theme.of(context).extension<VestigeSurfaces>() ?? _fallback;

  static const VestigeSurfaces _fallback = VestigeSurfaces(
    base: Color(0xFFEEF1F8),
    card: Color(0xFFFFFFFF),
    inset: Color(0xFFF1F4FA),
    border: Color(0xFFDDE1EA),
    cardShadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x08152540),
        blurRadius: 12,
        offset: Offset(0, 4),
      ),
      BoxShadow(
        color: Color(0x04152540),
        blurRadius: 3,
        offset: Offset(0, 1),
      ),
    ],
  );

  @override
  VestigeSurfaces copyWith({
    Color? base,
    Color? card,
    Color? inset,
    Color? border,
    List<BoxShadow>? cardShadow,
  }) =>
      VestigeSurfaces(
        base: base ?? this.base,
        card: card ?? this.card,
        inset: inset ?? this.inset,
        border: border ?? this.border,
        cardShadow: cardShadow ?? this.cardShadow,
      );

  @override
  VestigeSurfaces lerp(ThemeExtension<VestigeSurfaces>? other, double t) {
    if (other is! VestigeSurfaces) return this;
    return VestigeSurfaces(
      base: Color.lerp(base, other.base, t)!,
      card: Color.lerp(card, other.card, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      border: Color.lerp(border, other.border, t)!,
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t) ?? cardShadow,
    );
  }
}

/// 语义补充色（Material ColorScheme 里没有的角色）。
///
/// [backfill] 专门用于「补记」标记，让人一眼区分「当天记的」和「事后补的」。
@immutable
class VestigeTokens extends ThemeExtension<VestigeTokens> {
  const VestigeTokens({
    required this.backfill,
    required this.backfillContainer,
    required this.onBackfillContainer,
  });

  final Color backfill;
  final Color backfillContainer;
  final Color onBackfillContainer;

  static VestigeTokens of(BuildContext context) =>
      Theme.of(context).extension<VestigeTokens>() ?? _fallback;

  static const VestigeTokens _fallback = VestigeTokens(
    backfill: Color(0xFFB26A00),
    backfillContainer: Color(0xFFFFE0B2),
    onBackfillContainer: Color(0xFF3E2410),
  );

  @override
  VestigeTokens copyWith({
    Color? backfill,
    Color? backfillContainer,
    Color? onBackfillContainer,
  }) =>
      VestigeTokens(
        backfill: backfill ?? this.backfill,
        backfillContainer: backfillContainer ?? this.backfillContainer,
        onBackfillContainer: onBackfillContainer ?? this.onBackfillContainer,
      );

  @override
  VestigeTokens lerp(ThemeExtension<VestigeTokens>? other, double t) {
    if (other is! VestigeTokens) return this;
    return VestigeTokens(
      backfill: Color.lerp(backfill, other.backfill, t)!,
      backfillContainer:
          Color.lerp(backfillContainer, other.backfillContainer, t)!,
      onBackfillContainer:
          Color.lerp(onBackfillContainer, other.onBackfillContainer, t)!,
    );
  }
}

// ── 配色定义（值全部来自原 Kotlin Color.kt） ────────────────────────────

const ColorScheme _blueLight = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF1565C0),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFD1E4FF),
  onPrimaryContainer: Color(0xFF001D36),
  secondary: Color(0xFF545F70),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFD8E3F8),
  onSecondaryContainer: Color(0xFF111C2B),
  tertiary: Color(0xFF6D5E00),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFCE272),
  onTertiaryContainer: Color(0xFF211B00),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Color(0xFFF8F9FF),
  onSurface: Color(0xFF191C20),
  surfaceContainerHighest: Color(0xFFDFE2EB),
  onSurfaceVariant: Color(0xFF43474E),
  outline: Color(0xFF73777F),
  outlineVariant: Color(0xFFC3C6CF),
);

const ColorScheme _blueDark = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF9ECAFF),
  onPrimary: Color(0xFF003258),
  primaryContainer: Color(0xFF004A7C),
  onPrimaryContainer: Color(0xFFD1E4FF),
  secondary: Color(0xFFBCC7DB),
  onSecondary: Color(0xFF263141),
  secondaryContainer: Color(0xFF3C4858),
  onSecondaryContainer: Color(0xFFD8E3F8),
  tertiary: Color(0xFFDEC64C),
  onTertiary: Color(0xFF393000),
  tertiaryContainer: Color(0xFF524600),
  onTertiaryContainer: Color(0xFFFCE272),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF111318),
  onSurface: Color(0xFFE1E2E9),
  surfaceContainerHighest: Color(0xFF43474E),
  onSurfaceVariant: Color(0xFFC3C6CF),
  outline: Color(0xFF8D9199),
  outlineVariant: Color(0xFF43474E),
);

const ColorScheme _sageLight = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF59735A),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFDBF6D9),
  onPrimaryContainer: Color(0xFF162D19),
  secondary: Color(0xFF5A6158),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFDDE6D9),
  onSecondaryContainer: Color(0xFF171E17),
  tertiary: Color(0xFF8C7351),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFFDAB2),
  onTertiaryContainer: Color(0xFF342407),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Color(0xFFFDFDF8),
  onSurface: Color(0xFF1A1C19),
  surfaceContainerHighest: Color(0xFFDEE5D8),
  onSurfaceVariant: Color(0xFF424940),
  outline: Color(0xFF72796E),
  outlineVariant: Color(0xFFC2C9BD),
);

const ColorScheme _sageDark = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFBFD9BD),
  onPrimary: Color(0xFF2B432D),
  primaryContainer: Color(0xFF415A43),
  onPrimaryContainer: Color(0xFFDBF6D9),
  secondary: Color(0xFFC1C9BD),
  onSecondary: Color(0xFF2C332B),
  secondaryContainer: Color(0xFF424A41),
  onSecondaryContainer: Color(0xFFDDE6D9),
  tertiary: Color(0xFFEAD2A8),
  onTertiary: Color(0xFF452F15),
  tertiaryContainer: Color(0xFF5F452A),
  onTertiaryContainer: Color(0xFFFFECCC),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF1A1C19),
  onSurface: Color(0xFFE2E3DD),
  surfaceContainerHighest: Color(0xFF424940),
  onSurfaceVariant: Color(0xFFC1C9BD),
  outline: Color(0xFF8B9387),
  outlineVariant: Color(0xFF424940),
);

/// 取指定配色 + 明暗的 Material 3 配色。
ColorScheme vestigeColorScheme(AppThemeVariant variant, Brightness brightness) {
  return switch (variant) {
    AppThemeVariant.defaultBlue =>
      brightness == Brightness.dark ? _blueDark : _blueLight,
    AppThemeVariant.sageGreen =>
      brightness == Brightness.dark ? _sageDark : _sageLight,
  };
}

/// 「补记」语义色的两套取值。
const VestigeTokens _tokensLight = VestigeTokens(
  backfill: Color(0xFFB26A00),
  backfillContainer: Color(0xFFFFE0B2),
  onBackfillContainer: Color(0xFF3E2410),
);

const VestigeTokens _tokensDark = VestigeTokens(
  backfill: Color(0xFFFFC46B),
  backfillContainer: Color(0xFF6B4400),
  onBackfillContainer: Color(0xFFFFE0B2),
);

/// 四层表面色的两套（蓝 / 绿）× 两档（浅 / 深）取值。
///
/// 浅色下卡片走**纯白**、页面底降一档明度；深色下反过来，卡片比页面底亮一档。
/// 两套配色共享同一套明度关系，切换配色时层次不会变样。
const VestigeSurfaces _surfacesBlueLight = VestigeSurfaces(
  base: Color(0xFFEEF1F8),
  card: Color(0xFFFFFFFF),
  inset: Color(0xFFF1F4FA),
  border: Color(0xFFDDE1EA),
  cardShadow: <BoxShadow>[
    BoxShadow(
      color: Color(0x0A152540),
      blurRadius: 10,
      offset: Offset(0, 3),
    ),
    BoxShadow(
      color: Color(0x05152540),
      blurRadius: 3,
      offset: Offset(0, 1),
    ),
  ],
);

const VestigeSurfaces _surfacesBlueDark = VestigeSurfaces(
  base: Color(0xFF0C0F14),
  card: Color(0xFF181B21),
  inset: Color(0xFF23272F),
  border: Color(0xFF2E333C),
  cardShadow: <BoxShadow>[
    BoxShadow(
      color: Color(0x3D000000),
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ],
);

const VestigeSurfaces _surfacesSageLight = VestigeSurfaces(
  base: Color(0xFFF0F3EA),
  card: Color(0xFFFFFFFF),
  inset: Color(0xFFF3F6EF),
  border: Color(0xFFDDE3D6),
  cardShadow: <BoxShadow>[
    BoxShadow(
      color: Color(0x0D2B3D2C),
      blurRadius: 10,
      offset: Offset(0, 3),
    ),
    BoxShadow(
      color: Color(0x052B3D2C),
      blurRadius: 3,
      offset: Offset(0, 1),
    ),
  ],
);

const VestigeSurfaces _surfacesSageDark = VestigeSurfaces(
  base: Color(0xFF11140E),
  card: Color(0xFF1D211A),
  inset: Color(0xFF272C23),
  border: Color(0xFF343B2F),
  cardShadow: <BoxShadow>[
    BoxShadow(
      color: Color(0x3D000000),
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ],
);

/// 取指定配色 + 明暗的四层表面色。
VestigeSurfaces vestigeSurfaces(
  AppThemeVariant variant,
  Brightness brightness,
) {
  return switch (variant) {
    AppThemeVariant.defaultBlue => brightness == Brightness.dark
        ? _surfacesBlueDark
        : _surfacesBlueLight,
    AppThemeVariant.sageGreen => brightness == Brightness.dark
        ? _surfacesSageDark
        : _surfacesSageLight,
  };
}

/// 构建主题。圆角、子主题统一在这里配，页面里就不用到处写 shape。
ThemeData buildVestigeTheme(AppThemeVariant variant, Brightness brightness) {
  final scheme = vestigeColorScheme(variant, brightness);
  final surfaces = vestigeSurfaces(variant, brightness);
  final tokens = brightness == Brightness.dark ? _tokensDark : _tokensLight;

  final subThemes = FlexSubThemesData(
    // 极大圆角：卡片 24 / 输入框与控件 16 / 弹窗与底部面板 32
    defaultRadius: VestigeRadius.small,
    cardRadius: VestigeRadius.medium,
    inputDecoratorRadius: VestigeRadius.small,
    dialogRadius: VestigeRadius.large,
    bottomSheetRadius: VestigeRadius.large,
    fabRadius: VestigeRadius.medium,
    chipRadius: VestigeRadius.small,
    snackBarRadius: VestigeRadius.small,
    popupMenuRadius: VestigeRadius.small,
    navigationBarIndicatorRadius: VestigeRadius.small,
    navigationBarHeight: 66,
    navigationBarLabelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    // 控件交互反馈保持 Material 3 默认，避免和自定义配色打架
    interactionEffects: false,
    blendOnLevel: 0,
    blendOnColors: false,
    useMaterial3Typography: true,
  );

  final theme = brightness == Brightness.dark
      ? FlexThemeData.dark(
          colorScheme: scheme,
          useMaterial3: true,
          blendLevel: 0,
          subThemesData: subThemes,
          visualDensity: VisualDensity.standard,
          pageTransitionsTheme: _transitions,
        )
      : FlexThemeData.light(
          colorScheme: scheme,
          useMaterial3: true,
          blendLevel: 0,
          subThemesData: subThemes,
          visualDensity: VisualDensity.standard,
          pageTransitionsTheme: _transitions,
        );

  // 输入框统一成「填充 + 16 圆角、无描边，聚焦才出主色描边」。
  // 改版前这里是框架默认的 4 圆角全描边，和 24 圆角的卡片摆在一页里像两个 App。
  final fieldBorder = OutlineInputBorder(
    borderRadius: VestigeRadius.smallAll,
    borderSide: BorderSide(color: surfaces.border),
  );

  return theme.copyWith(
    // 页面底与容器面分层：卡片纯白浮在浅灰底上，不再靠 1px 描边证明存在。
    scaffoldBackgroundColor: surfaces.base,
    extensions: <ThemeExtension<dynamic>>[tokens, surfaces],
    cardTheme: theme.cardTheme.copyWith(
      elevation: 0.8,
      shadowColor: scheme.shadow.withValues(alpha: 0.05),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: surfaces.card,
      // 描边在这里统一给：卡片靠明度差「浮起」，描边只负责把边缘收干净。
      // 放在主题里而不是各页面自己写，是为了「所有卡片长得一样」这件事只有一个出处。
      // （首页记录卡因为要区分选中态，会在 widget 里覆盖 shape —— 那是唯一的例外。）
      shape: RoundedRectangleBorder(
        borderRadius: VestigeRadius.mediumAll,
        side: BorderSide(color: surfaces.border, width: 0.8),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // 输入框走**容器白**，不是卡内凹槽色：输入框大多直接坐在页面底上
      // （编辑页的标题、内容），用凹槽色（#F1F4FA）叠在页面底（#EEF1F8）上
      // 只差 1.3% 明度 —— 又是「几乎看不见」。白底 + 描边才浮得起来。
      fillColor: surfaces.card,
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: VestigeRadius.smallAll,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w700,
      ),
      helperStyle: TextStyle(color: scheme.onSurfaceVariant),
      hintStyle: TextStyle(color: scheme.outline),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
    ),
    // Chip 也走圆角刻度。M3 默认是两端全圆的胶囊；同一张卡里既有 12/16 的
    // 输入格又有胶囊 chip 时，形状语言会分家。16 在高 32 的标签 chip 上仍接近
    // 半圆（观感不变），但在高 36 的动作 chip 上会明确读成圆角矩形。
    chipTheme: theme.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
    ),
    dividerTheme: DividerThemeData(
      thickness: 0.6,
      space: 0.6,
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      centerTitle: false,
      elevation: 0,
      // 顶栏与页面底同色：滚动时不再被 surfaceTint 染成另一种色调，
      // 视觉上「页面从顶栏下方长出来」，而不是顶栏浮在页面上。
      scrolledUnderElevation: 0,
      backgroundColor: surfaces.base,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: theme.navigationBarTheme.copyWith(
      backgroundColor: surfaces.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
    ),
    // 弹层与对话框也走实色容器面。
    // 这里必须显式配：ColorScheme 是手写的（只给了 surface / surfaceContainerHighest），
    // 没配到的 surfaceContainerLow 等角色会落回 Material 3 的 baseline 默认值
    // （一套和本 App 配色无关的紫灰），弹层于是白得发紫。
    dialogTheme: theme.dialogTheme.copyWith(
      backgroundColor: surfaces.card,
      surfaceTintColor: Colors.transparent,
      // 居中弹层（标签筛选/年份/操作历史等）与 AlertDialog 统一 32 圆角 ——
      // 与日期选择器同一档，形状语言不再分家。antiAlias 让弹层内滚动的
      // 列表内容裁进圆角里，不会顶出去。
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.largeAll),
      clipBehavior: Clip.antiAlias,
    ),
    bottomSheetTheme: theme.bottomSheetTheme.copyWith(
      backgroundColor: surfaces.card,
      modalBackgroundColor: surfaces.card,
      surfaceTintColor: Colors.transparent,
    ),
    // 日历 / 时钟弹层和对话框同理，且此处更容易出错：
    // 它俩的 M3 默认底色取的是 `surfaceContainerHigh`（日期）和 `surfaceContainerHigh`
    // （时间）—— 这两个角色**我们手写的 ColorScheme 里根本没有**，会静默落回
    // Material 3 的 baseline 紫灰。日历一弹出来就是「另一个 App」的味道。
    // 底、圆角、标题带都显式给，弹层才和页面是一套。
    datePickerTheme: theme.datePickerTheme.copyWith(
      backgroundColor: surfaces.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.largeAll),
      // 标题带（显示当前选中日）走容器色：M3 默认是透明的，
      // 一块全白的弹层里少一层层次，而且选中的日期没有落脚点。
      headerBackgroundColor: scheme.primaryContainer,
      headerForegroundColor: scheme.onPrimaryContainer,
    ),
    timePickerTheme: theme.timePickerTheme.copyWith(
      backgroundColor: surfaces.card,
      shape: RoundedRectangleBorder(borderRadius: VestigeRadius.largeAll),
      // 表盘底留 M3 默认的 surfaceContainerHighest（本 App 配色里有定义）：
      // 换成卡内凹槽色会在白弹层上淡到看不见表盘。
      // **不要**覆盖 hourMinute* / dayPeriod*：它们的默认值是 WidgetStateColor，
      // 选中态用 primaryContainer / tertiaryContainer，覆盖成实色会把选中高亮抹掉。
      entryModeIconColor: scheme.primary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        // 注意不能写裸的 `TextStyle(fontWeight: ...)`：
        // `ButtonStyleButton` 拿到主题给的 textStyle 后是**整个替换**
        // `textTheme.labelLarge`（不是 merge），裸 TextStyle 的 fontFamily 为 null，
        // 文字就会回落到引擎默认字体 —— 测试环境是 Ahem（全方块），
        // 真机上虽然能显示，但也一路丢掉了 labelLarge 的字号与字距。
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: VestigeRadius.smallAll),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
  );
}

/// 各平台的转场：Android 用预测式返回，iOS/macOS 用 Cupertino，
/// 桌面端用 Material 3 的淡入前推，整体观感统一。
const PageTransitionsTheme _transitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
  },
);
