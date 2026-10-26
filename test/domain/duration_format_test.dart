// 时长格式化（秒 → 人读文案）的边界测试。
//
// 存储一律秒；这几档是展示层唯一的「单位选择规则」，卡片标签、统计卡、
// 弹层预览都吃它，写歪了会同时错一片。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/duration_format.dart';

void main() {
  group('durationLabel · 长格式', () {
    test('不满 1 分钟说秒', () {
      expect(durationLabel(1), '1 秒');
      expect(durationLabel(59), '59 秒');
    });

    test('满 1 分钟不满 1 小时说分钟，非零秒数不被吞掉', () {
      expect(durationLabel(60), '1 分钟');
      expect(durationLabel(45 * 60), '45 分钟');
      expect(durationLabel(90), '1 分钟 30 秒');
      expect(durationLabel(3599), '59 分钟 59 秒');
    });

    test('满 1 小时换算成时 / 时分，秒数单独成段', () {
      expect(durationLabel(3600), '1 小时');
      expect(durationLabel(80 * 60), '1 小时 20 分钟');
      expect(durationLabel(2 * 3600 + 5 * 60), '2 小时 5 分钟');
      // 分钟为 0 时不要出现「0 分钟」
      expect(durationLabel(3630), '1 小时 30 秒');
      expect(durationLabel(3661), '1 小时 1 分钟 1 秒');
    });
  });

  group('durationLabelCompact · 紧凑格式', () {
    test('三档单位 + 秒数后缀', () {
      expect(durationLabelCompact(45), '45秒');
      expect(durationLabelCompact(5 * 60), '5分');
      expect(durationLabelCompact(90), '1分30秒');
      expect(durationLabelCompact(80 * 60), '1时20分');
      expect(durationLabelCompact(2 * 3600), '2时');
      expect(durationLabelCompact(3661), '1时1分1秒');
    });
  });

  group('elapsedClockLabel · 计时钟面', () {
    test('不满 1 小时是 MM:SS', () {
      expect(elapsedClockLabel(0), '00:00');
      expect(elapsedClockLabel(65), '01:05');
    });

    test('满 1 小时进位成 H:MM:SS', () {
      expect(elapsedClockLabel(3600), '1:00:00');
      expect(elapsedClockLabel(3725), '1:02:05');
    });
  });
}
