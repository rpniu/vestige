import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vestige/app/theme.dart';

/// 滑动时浮现的「一键到底 / 一键到顶」按钮 —— **只有一个按钮**，
/// 它的功能跟着用户当前的操作灵活变化：
///
/// - 正在往下翻（内容往上走、offset 变大）→ 显示「↓ 到底」，一点直达列表末尾；
/// - 正在往上翻（offset 变小）→ 显示「↑ 到顶」，一点回到最上面；
/// - 已经在顶部 → 强制显示「到底」（往上的方向没意义了）；
/// - 已经在底部 → 强制显示「到顶」；
/// - 列表不够长（没得滚）→ 整个不出现。
///
/// 换句话说，这个按钮永远提供「**顺着你正在看的方向，直接走到头**」的快捷方式，
/// 不用用户去想「我该点到顶还是到底」——方向由他的滑动决定，边界位置再兜一层。
///
/// 外观：**和右下角「记一笔」FAB 等大的正方形按钮**（默认 56，圆角 18），
/// 只放一个箭头图标，不带文字、不带 tooltip（只留 Semantics 给读屏）。
///
/// 出现/消失同样是滑动驱动的：一开始滚就淡入，停手 [hideDelay] 后自动淡出。
class ScrollJumpButton extends StatefulWidget {
  const ScrollJumpButton({
    super.key,
    required this.controller,
    this.hideDelay = const Duration(seconds: 2),
    this.edgeThreshold = 12,
    this.side = 56,
    this.iconSize = 28,
  });

  /// 被控制的列表（必须已 attach）。
  final ScrollController controller;

  /// 跳转动画的时长。
  ///
  /// 抽成公开常量有两个用处：一是「一键到顶/到底」的手感只在这里定义一次；
  /// 二是性能回归测试必须按**同一套参数**复现那一下（跳转的帧数是它决定的）。
  static const Duration jumpDuration = Duration(milliseconds: 320);

  /// 跳转动画的曲线。
  ///
  /// 用 `easeOutCubic`：首帧就推进约全程的 14%，观感是「一下就窜过去」。
  /// 注意这条曲线会把工作量压在开头几帧 —— 在旧实现（`SliverList` 逐行走）下
  /// 这正是卡顿的来源；现在行高可预知、跳转是算术定位，首帧推进多远都无所谓了。
  static const Curve jumpCurve = Curves.easeOutCubic;

  /// 停止滚动后多久自动隐藏。
  final Duration hideDelay;

  /// 距顶/底多少像素以内算「已经在顶部/底部」。
  final double edgeThreshold;

  /// 按钮边长（正方形）。默认 56，和右下角「记一笔」FAB 等大。
  final double side;

  final double iconSize;

  @override
  State<ScrollJumpButton> createState() => _ScrollJumpButtonState();
}

class _ScrollJumpButtonState extends State<ScrollJumpButton> {
  Timer? _hideTimer;
  bool _visible = false;
  bool _atTop = true;
  bool _atBottom = true;

  /// 最近一次滚动的方向：1 = 往下翻（offset 变大），-1 = 往上翻。
  /// 初始给 -1，这样停在中间时默认提供更常用的「回到顶部」。
  double _lastDirection = -1;

  /// 上一次的滚动位置。null 表示还没收到过滚动事件 ——
  /// 第一帧不能用它算方向（那时 offset 可能早就不是 0 了，会算出一个假方向）。
  double? _lastPixels;

  /// **按钮当前显示的方向，同时也是点击后会去的方向**。
  /// 存成状态字段而不是 getter：图标和动作必须来自同一份数据，
  /// 否则方向翻转时如果没触发重建，就会出现「图标还指着上一帧、点下去却跑另一边」。
  bool _goBottom = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollJumpButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hideTimer?.cancel();
    super.dispose();
  }

  /// 当前该去哪儿：边界位置强制，中间区域跟着滑动方向走。
  bool _resolveGoBottom({
    required bool atTop,
    required bool atBottom,
  }) {
    if (atTop) return true;
    if (atBottom) return false;
    return _lastDirection > 0;
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final pixels = position.pixels;
    final atTop = pixels <= widget.edgeThreshold;
    final atBottom =
        pixels >= position.maxScrollExtent - widget.edgeThreshold;

    // 记录滚动方向（只有真的动了才更新，避免微小抖动翻来翻去）。
    // 第一次滚动事件只用来记住位置，不判方向。
    final last = _lastPixels;
    if (last != null) {
      final delta = pixels - last;
      if (delta.abs() > 0.5) {
        _lastDirection = delta > 0 ? 1 : -1;
      }
    }
    _lastPixels = pixels;

    // 两头都够不着（列表没得滚）→ 整个不显示
    if (atTop && atBottom) {
      if (_visible || _atTop != atTop || _atBottom != atBottom) {
        setState(() {
          _visible = false;
          _atTop = atTop;
          _atBottom = atBottom;
        });
      }
      return;
    }

    final goBottom = _resolveGoBottom(atTop: atTop, atBottom: atBottom);

    _hideTimer?.cancel();
    _hideTimer = Timer(widget.hideDelay, () {
      if (mounted) setState(() => _visible = false);
    });

    // 注意：方向变化（goBottom 变了）也要重建，
    // 否则图标会停在上一帧，而点下去已经跑到另一边 —— 就是「图标和功能不一致」。
    if (!_visible ||
        _atTop != atTop ||
        _atBottom != atBottom ||
        _goBottom != goBottom) {
      setState(() {
        _visible = true;
        _atTop = atTop;
        _atBottom = atBottom;
        _goBottom = goBottom;
      });
    }
  }

  Future<void> _jump() async {
    if (!widget.controller.hasClients) return;
    // 用「当前显示的那个方向」来决定去哪，保证点了和看到的一致
    final target =
        _goBottom ? widget.controller.position.maxScrollExtent : 0.0;
    await widget.controller.animateTo(
      target,
      duration: ScrollJumpButton.jumpDuration,
      curve: ScrollJumpButton.jumpCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surfaces = VestigeSurfaces.of(context);
    final goBottom = _goBottom;

    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedSlide(
          offset: _visible ? Offset.zero : const Offset(0, 0.12),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          // 正方形、和右下角 FAB 等大；只用图标，不带文字和 tooltip，
          // 但保留 Semantics 标签，读屏用户仍能知道这个按钮是干什么的。
          child: Semantics(
            button: true,
            label: goBottom ? '到底' : '到顶',
            child: SizedBox(
              width: widget.side,
              height: widget.side,
              child: Material(
                // 和卡片同一个容器面：这个按钮是浮在列表之上的「同类物件」，
                // 之前那个 94% 半透明的近底色在浅色下几乎和页面底同色，
                // 只靠 elevation 阴影撑着，看起来发虚。
                color: surfaces.card,
                elevation: 3,
                borderRadius: _shapeFor(widget.side),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _jump,
                  child: Center(
                    // 图标切换带动画：功能变了看得出来，但整块不跳动
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: Icon(
                        goBottom
                            ? Icons.vertical_align_bottom
                            : Icons.vertical_align_top,
                        key: ValueKey<bool>(goBottom),
                        size: widget.iconSize,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 与右下角「记一笔」FAB 一致的圆角：按边长等比给（56 → 18）。
  /// 注意不是 Material 默认的 16 —— 首页 FAB 显式写的就是 18，
  /// 这两个按钮上下叠着，圆角必须同值，否则并排看会「差一点」。
  static BorderRadius _shapeFor(double side) =>
      BorderRadius.circular(side * 18 / 56);
}
