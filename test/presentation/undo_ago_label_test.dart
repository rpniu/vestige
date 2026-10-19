// 操作历史里「多久之前」的文案测试。
//
// 单独测是因为它是个纯函数、而且边界很容易写错：
// 59 秒 / 60 秒、59 分 / 60 分、23 小时 / 24 小时 —— 每一档的临界点都在这里钉住。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/presentation/widgets/undo_history_sheet.dart';

void main() {
  final DateTime now = DateTime(2026, 9, 23, 21, 0);

  String ago(Duration d) => undoAgoLabel(now.subtract(d), now);

  test('一分钟以内是「刚刚」', () {
    expect(ago(Duration.zero), '刚刚');
    expect(ago(const Duration(seconds: 59)), '刚刚');
  });

  test('分钟档', () {
    expect(ago(const Duration(seconds: 60)), '1 分钟前');
    expect(ago(const Duration(minutes: 59)), '59 分钟前');
  });

  test('小时档', () {
    expect(ago(const Duration(minutes: 60)), '1 小时前');
    expect(ago(const Duration(hours: 23)), '23 小时前');
  });

  test('天档', () {
    expect(ago(const Duration(hours: 24)), '1 天前');
    expect(ago(const Duration(days: 29)), '29 天前');
  });

  test('超过 30 天就直接给日期', () {
    expect(ago(const Duration(days: 30)), '2026/8/24');
    expect(ago(const Duration(days: 200)), '2026/3/7');
  });

  test('时间在未来（设备时钟被改过）也兜得住，不显示负数', () {
    expect(undoAgoLabel(now.add(const Duration(hours: 3)), now), '刚刚');
  });
}
