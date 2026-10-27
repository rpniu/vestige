// 2026-10-27 代码审查修复项的回归测试（domain / CSV）。
//
// 对照本地的审查报告 `temp/review/code-review-2026-10-27.md`（按规定不入库）：
// - M-004 导入 id 的安全校验（路由/保留字）
// - M-009 导出 CSV 的公式注入中和，且能无损往返
// - m-003 表头识别要求命中两个已知列名

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/csv_util.dart';

void main() {
  RecordEntity record({
    String id = 'a1',
    String content = '内容',
    String? title,
    List<String> tags = const <String>[],
  }) {
    final at = DateTime(2026, 10, 1, 9, 30);
    return RecordEntity(
      id: id,
      title: title,
      content: content,
      tags: tags,
      recordedAt: at,
      createdAt: at,
      updatedAt: at,
      deleted: false,
      durationS: null,
    );
  }

  /// 造一行 CSV 数据（8 列，无表头）。
  String row({
    String id = 'a1',
    String title = '',
    String content = '内容',
    String tags = '',
    String duration = '',
  }) =>
      '$id,$title,$content,$tags,1759300000000,1759300000000,1759300000000,'
      '$duration\n';

  group('[M-004] 导入 id 安全校验', () {
    test('含路径分隔符的 id 会被换成 UUID（否则路由打不开）', () {
      final result = CsvUtil.parse(row(id: 'a/b'));
      final id = result.records.single.id;
      expect(id, isNot('a/b'));
      expect(
        RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id),
        isTrue,
        reason: '不合规 id 应重新生成为 UUID',
      );
    });

    test('保留字 new 会被换掉（否则点它等于「新建」）', () {
      expect(CsvUtil.parse(row(id: 'new')).records.single.id, isNot('new'));
      expect(
        CsvUtil.parse(row(id: 'new@2026-10-01')).records.single.id,
        isNot('new@2026-10-01'),
      );
    });

    test('合规 id 原样保留（导入的幂等锚点不能变）', () {
      expect(CsvUtil.parse(row(id: 'a1')).records.single.id, 'a1');
      expect(
        CsvUtil.parse(row(id: '21442eaa-6943-49e3-958e-99ddc3a09023'))
            .records
            .single
            .id,
        '21442eaa-6943-49e3-958e-99ddc3a09023',
      );
    });
  });

  group('[M-009] 公式注入中和', () {
    test('以 = 开头的正文导出时被前置单引号', () {
      final csv = CsvUtil.export(<RecordEntity>[record(content: '=1+1')]);
      expect(csv, contains("'=1+1"));
    });

    test('以 + / - / @ 开头的正文同样被中和', () {
      for (final danger in const <String>['+1', '-1', '@SUM(A1)']) {
        final csv = CsvUtil.export(<RecordEntity>[record(content: danger)]);
        expect(csv, contains("'$danger"), reason: '$danger 会被表格软件当公式');
      }
    });

    test('导出 → 导入内容无损（不含多余引号）', () {
      final original = record(content: '=1+1', title: '@标题');
      final csv = CsvUtil.export(<RecordEntity>[original]);
      final back = CsvUtil.parse(csv).records.single;
      expect(back.content, '=1+1');
      expect(back.title, '@标题');
    });

    test('普通正文不会被加引号', () {
      final csv = CsvUtil.export(<RecordEntity>[record(content: '正常内容')]);
      expect(csv, isNot(contains("'正常内容")));
    });
  });

  group('[m-003] 表头识别', () {
    test('正文恰好是 content 的数据行不会被当成表头吃掉', () {
      // 只有一列命中（CONTENT），不够两个 → 视为数据行
      final result = CsvUtil.parse('a1,,content,,,,,\n');
      expect(result.records, hasLength(1));
      expect(result.records.single.content, 'content');
    });

    test('真正的表头仍然被识别并跳过', () {
      final csv = '${CsvUtil.headers.join(',')}\n${row(id: 'a1')}';
      final result = CsvUtil.parse(csv);
      expect(result.records, hasLength(1));
      expect(result.records.single.id, 'a1');
    });
  });
}
