import 'package:flutter/material.dart';
import 'package:vestige/app/theme.dart';

/// 数据读取失败态：说清「出了什么事」+ 给一次重试。
///
/// 为什么必须单独存在（2026-10-27 审查 C-001）：首页 / 统计 / 我的三处原先都用
/// `valueOrNull` 把 `AsyncError` 折成空集合，于是**库打不开、迁移失败**这类故障
/// 在界面上表现为「还没有任何记录」「统计全是 0」—— 与「数据真的没了」完全无法区分。
/// 2026-09-24 那次真实事故（迁移非幂等导致查询全失败）就是这样被用户误读的。
///
/// 所以只要 `recordsProvider` 处于错误态，就必须让错误**显眼地露出来**：
/// 用户哪怕看不懂细节，也拿得到一个「重试」出口；报障时截图里的错误信息能直接定位。
class VestigeErrorState extends StatelessWidget {
  const VestigeErrorState({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = '数据读取失败',
    this.subtitle = '记录可能仍在本地，先重试一次；反复失败请勿清空数据目录。',
  });

  /// 原始错误对象，原样展示 —— 它比任何概括都更有助于定位。
  final Object error;

  final VoidCallback onRetry;

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = VestigeSurfaces.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 图标走 error 配色的中性盘：与空态（主色盘）在语义上明确分开 ——
            // 「这里没有内容」和「这里读不出来」是两件事。
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
              ),
              child: Icon(
                Icons.error_outline_rounded,
                size: 36,
                color: scheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: surfaces.inset,
                borderRadius: VestigeRadius.smallAll,
                border: Border.all(color: surfaces.border),
              ),
              child: Text(
                '$error',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
