import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vestige/data/config/home_layout_config.dart';

/// 首页按钮列停靠边配置（`<数据目录>/config/home_buttons.json`）。
///
/// 三颗按钮（记一笔 / 速记 / 到顶到底）作为一整列停靠同侧，state 就是
/// 一个 [ButtonSide]。用 [Notifier]：既要在启动时从文件读进来，又要被
/// 「我的」页的 GUI 开关**就地改掉并立即生效**（不用重启）。语义：
/// - 初始状态是默认值（右侧），文件内容异步读入后覆盖；
/// - 用户在 GUI 里改过之后（`_dirty`），迟到的文件加载不再反向覆盖；
/// - 修改是「先更新 state（UI 立即换边）、再异步写盘」，写盘失败静默保持
///   内存态 —— 布局是个纯偏好，不值得为它弹错误框。
final homeButtonLayoutProvider =
    NotifierProvider<HomeButtonLayoutNotifier, ButtonSide>(
  HomeButtonLayoutNotifier.new,
);

class HomeButtonLayoutNotifier extends Notifier<ButtonSide> {
  /// 用户是否已经在本次会话里改过设置；改过就不再让迟到的文件加载覆盖。
  bool _dirty = false;

  @override
  ButtonSide build() {
    loadButtonSideFromPlatform().then((side) {
      if (!_dirty) state = side;
    }).catchError((Object _) {
      // 读不出来（平台通道不可用、文件系统异常）就保持默认值。
    });
    return defaultButtonSide;
  }

  /// 设置整列按钮的停靠边（三颗一起换边）。
  Future<void> setSide(ButtonSide side) async {
    _dirty = true;
    state = side;
    try {
      await saveButtonSideToPlatform(side);
    } catch (_) {
      // 写盘失败不回滚：内存态已生效，下次改动会再写一次。
    }
  }
}
