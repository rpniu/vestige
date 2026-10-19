// 日期范围 chip 的文案测试。
//
// 重点是「跨年要显示年份」那条分支 —— 页面上很难点到，但用户一旦跨年选范围
// 就会看到；写错了会读成「2026/12/1 – 1/5」，像是倒着走。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/presentation/screens/search_screen.dart';

void main() {
  test('同年：右边省掉年份，短一截', () {
    expect(
      searchRangeLabel(
        DateTimeRange(start: DateTime(2026, 8, 1), end: DateTime(2026, 8, 31)),
      ),
      '2026/8/1 – 8/31',
    );
  });

  test('跨年：两边都带年份', () {
    expect(
      searchRangeLabel(
        DateTimeRange(start: DateTime(2026, 12, 1), end: DateTime(2027, 1, 5)),
      ),
      '2026/12/1 – 2027/1/5',
    );
  });

  test('同一天：右边把月日再写一遍，保持「这是个区间」的读法', () {
    expect(
      searchRangeLabel(
        DateTimeRange(start: DateTime(2026, 8, 1), end: DateTime(2026, 8, 1)),
      ),
      '2026/8/1 – 8/1',
    );
  });
}
