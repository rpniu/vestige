import 'package:flutter/material.dart';
import 'package:vestige/app/motion.dart';
import 'package:vestige/app/theme.dart';

/// 通用空态：图标圆盘 + 主句 + 弱化副句，带一次性的淡入上移入场。
///
/// 首页 / 搜索 / 回收站各自原来都手写了一份「图标坐进圆盘 + 两行文案」，
/// 观感细节各差半档（圆盘底色、描边、字号）。这里收敛成一个组件：
/// - 圆盘走 `inset` 底 + `border` 描边的中性盘（首页那个带主色光环的特例
///   保留在首页 —— 全 App 第一个空态值得更隆重）；
/// - 入场用 [TweenAnimationBuilder] 做一次 320ms 的透明度 + 8px 上移，
///   只在本组件首次构建时播放，不随列表复用反复触发。
///
/// 文案由调用方传入，组件不内置任何业务语义；接入时保持原有文案字符串
/// 不变，widget 测试按文本查找的断言不受影响。
class VestigeEmptyState extends StatelessWidget {
  const VestigeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  /// 空态主图标（建议传 `*_rounded` 家族）。
  final IconData icon;

  /// 主句。
  final String title;

  /// 弱化副句，可为空。
  final String? subtitle;

  /// 主句/副句之外的附加内容（如引导卡、占位高度），插在最后。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: VestigeMotion.slow,
      curve: VestigeMotion.curve,
      builder: (context, t, _) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: surfaces.inset,
                  shape: BoxShape.circle,
                  border: Border.all(color: surfaces.border),
                ),
                child: Icon(icon, size: 34, color: scheme.outline),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
