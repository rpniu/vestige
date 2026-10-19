import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/csv_util.dart';
import 'package:vestige/domain/day_util.dart';

/// 旧版（Kotlin / Go）导出的 6 列格式：没有 RecordedAt。
const String _legacyCsv = 'ID,Title,Content,Tags,CreatedAt,UpdatedAt\n'
    '21442eaa-6943-49e3-958e-99ddc3a09023,,e,,1787831939661,1787831944730\n'
    '7d64a44e-8b06-4664-8c31-1cbb130fbb64,,2,,1787270400000,1787386016987\n';

RecordEntity _record({
  required String id,
  required DateTime recordedAt,
  required DateTime createdAt,
  String content = '1',
  String? title,
  List<String> tags = const <String>[],
}) =>
    RecordEntity(
      id: id,
      title: title,
      content: content,
      tags: tags,
      recordedAt: recordedAt,
      createdAt: createdAt,
      updatedAt: createdAt,
      deleted: false,
    );

void main() {
  group('导出', () {
    test('表头为新 7 列，时间写毫秒时间戳', () {
      final csv = CsvUtil.export(
        <RecordEntity>[
          _record(
            id: 'a1',
            recordedAt: DateTime(2026, 9, 10, 21, 30),
            createdAt: DateTime(2026, 9, 15, 11, 0),
            content: '补记的',
            tags: const <String>['运动'],
          ),
        ],
        withBom: false,
      );
      final lines = csv.trim().split('\n');
      expect(lines.first, CsvUtil.headers.join(','));
      expect(
        lines[1].split(',').first,
        'a1',
      );
      expect(
        lines[1].contains(
          '${DateTime(2026, 9, 10, 21, 30).millisecondsSinceEpoch}',
        ),
        isTrue,
      );
      expect(lines[1].contains('运动'), isTrue);
    });

    test('默认输出 UTF-8 BOM，方便 Excel 正确识别中文', () {
      final csv = CsvUtil.export(const <RecordEntity>[]);

      expect(csv.startsWith(CsvUtil.bom), isTrue);
      expect(csv.codeUnitAt(0), 0xFEFF);
      // 落盘后的头三个字节必须是 EF BB BF
      expect(utf8.encode(csv).take(3).toList(), <int>[0xEF, 0xBB, 0xBF]);
      // 表头在 BOM 之后，且首行不是空的
      expect(csv.split('\n').first, '${CsvUtil.bom}${CsvUtil.headers.join(',')}');
    });

    test('withBom: false 时没有 BOM', () {
      final csv = CsvUtil.export(const <RecordEntity>[], withBom: false);
      expect(csv.startsWith(CsvUtil.bom), isFalse);
      expect(csv.codeUnitAt(0), 'I'.codeUnitAt(0));
    });
  });

  group('BOM 与解析的配合', () {
    test('自己导出的 BOM 文件能被自己解析回来，且不产生多余行', () {
      final original = <RecordEntity>[
        _record(
          id: 'a1',
          recordedAt: DateTime(2026, 9, 10, 21, 30),
          createdAt: DateTime(2026, 9, 15, 11, 0),
          title: '中文标题',
          content: '中文内容',
        ),
      ];

      final result = CsvUtil.parse(CsvUtil.export(original));

      expect(result.skipped, 0);
      expect(result.errors, isEmpty);
      expect(result.records.single.id, 'a1');
      expect(result.records.single.title, '中文标题');
      expect(result.records.single.content, '中文内容');
    });

    test('导出→导入→再导出，文本完全一致（幂等）', () {
      final original = <RecordEntity>[
        _record(
          id: 'a1',
          recordedAt: DateTime(2026, 9, 10, 21, 30),
          createdAt: DateTime(2026, 9, 15, 11, 0),
          title: '含,逗号',
          content: '换行\n内容 "引号"',
          tags: const <String>['运动', '读书'],
        ),
        _record(
          id: 'a2',
          recordedAt: DateTime(2026, 9, 15, 9),
          createdAt: DateTime(2026, 9, 15, 9, 1),
          content: '当天记的',
        ),
      ];

      final firstPass = CsvUtil.export(original);
      final secondPass = CsvUtil.export(CsvUtil.parse(firstPass).records);

      expect(secondPass, firstPass);
    });

    test('多个 BOM 前缀（有的工具会重复写）也能解析', () {
      final csv = '${CsvUtil.bom}${CsvUtil.bom}ID,Content,CreatedAt,UpdatedAt\n'
          'a1,hello,1787831939661,1787831939661\n';
      final result = CsvUtil.parse(csv);
      expect(result.records.single.id, 'a1');
      expect(result.records.single.content, 'hello');
    });
  });

  group('导入 · 新格式', () {
    test('导出再导入，字段不丢（含补记标记）', () {
      final original = <RecordEntity>[
        _record(
          id: 'a1',
          recordedAt: DateTime(2026, 9, 10, 21, 30),
          createdAt: DateTime(2026, 9, 15, 11, 0),
          content: '含,逗号 与 "引号" 的内容',
          title: '标题',
          tags: const <String>['运动', '读书'],
        ),
        _record(
          id: 'a2',
          recordedAt: DateTime(2026, 9, 15, 9),
          createdAt: DateTime(2026, 9, 15, 9, 1),
          content: '当天记的',
        ),
      ];

      final result = CsvUtil.parse(CsvUtil.export(original));

      expect(result.skipped, 0);
      expect(result.records.length, 2);
      expect(result.backfilledCount, 1);

      final first = result.records.first;
      expect(first.id, 'a1');
      expect(first.title, '标题');
      expect(first.content, '含,逗号 与 "引号" 的内容');
      expect(first.tags, <String>['运动', '读书']);
      expect(first.recordedAt, DateTime(2026, 9, 10, 21, 30));
      expect(first.createdAt, DateTime(2026, 9, 15, 11, 0));
      expect(first.isBackfilled, isTrue);
      expect(result.records[1].isBackfilled, isFalse);
    });

    test('引号内的换行不会把一行拆成两行', () {
      final original = <RecordEntity>[
        _record(
          id: 'a1',
          recordedAt: DateTime(2026, 9, 15, 8),
          createdAt: DateTime(2026, 9, 15, 8),
          content: '第一行\n第二行',
        ),
      ];
      final result = CsvUtil.parse(CsvUtil.export(original));
      expect(result.records.single.content, '第一行\n第二行');
    });
  });

  group('导入 · 旧格式兼容', () {
    test('6 列旧格式：把 CreatedAt 当作记录日期，不标成补记', () {
      final result = CsvUtil.parse(_legacyCsv);

      expect(result.records.length, 2);
      expect(result.skipped, 0);
      expect(result.backfilledCount, 0);

      final first = result.records.first;
      expect(first.id, '21442eaa-6943-49e3-958e-99ddc3a09023');
      expect(first.content, 'e');
      expect(first.createdAt, DateTime.fromMillisecondsSinceEpoch(1787831939661));
      expect(first.recordedAt, first.createdAt);
      expect(first.isBackfilled, isFalse);
    });

    test('秒级时间戳自动 ×1000', () {
      const legacySeconds = 'ID,Title,Content,Tags,CreatedAt,UpdatedAt\n'
          'a1,,hello,,1787831939,1787831944\n';
      final result = CsvUtil.parse(legacySeconds);
      final record = result.records.single;
      expect(
        record.recordedAt,
        DateTime.fromMillisecondsSinceEpoch(1787831939000),
      );
    });

    test('无表头的 6 列裸数据按旧列序解析', () {
      const noHeader = 'a1,,hello,,1787831939661,1787831944730\n';
      final result = CsvUtil.parse(noHeader);
      final record = result.records.single;
      expect(record.id, 'a1');
      expect(record.content, 'hello');
      expect(record.recordedAt.millisecondsSinceEpoch, 1787831939661);
    });

    test('无表头的 7 列裸数据按新列序解析', () {
      final recorded = DateTime(2026, 9, 10, 12);
      final created = DateTime(2026, 9, 15, 12);
      final noHeader = 'a1,,补记,标签,'
          '${recorded.millisecondsSinceEpoch},'
          '${created.millisecondsSinceEpoch},'
          '${created.millisecondsSinceEpoch}\n';
      final result = CsvUtil.parse(noHeader);
      final record = result.records.single;
      expect(record.recordedAt, recorded);
      expect(record.createdAt, created);
      expect(record.tags, <String>['标签']);
      expect(record.isBackfilled, isTrue);
    });

    test('列顺序打乱也能按表头匹配', () {
      const shuffled = 'Recorded At,Content,ID,Created_At,Tags,Title,Updated At\n'
          '2026-09-10T21:30:00,hello,a1,2026-09-15T11:00:00,运动,标题,'
          '2026-09-15T11:00:00\n'
          '2026-09-11T21:30:00,world,a2,2026-09-15T11:00:00,读书,标题2,'
          '2026-09-15T11:00:00\n';
      final result = CsvUtil.parse(shuffled);
      expect(result.records.length, 2);
      final first = result.records.first;
      expect(first.id, 'a1');
      expect(first.content, 'hello');
      expect(first.tags, <String>['运动']);
      expect(first.title, '标题');
      expect(first.recordedAt, DateTime(2026, 9, 10, 21, 30));
      expect(first.createdAt, DateTime(2026, 9, 15, 11));
    });

    test('ISO-8601 字符串时间可用', () {
      const isoCsv = 'ID,Content,RecordedAt,CreatedAt\n'
          'a1,hello,2026-09-10T21:30:00,2026-09-15T11:00:00\n';
      final result = CsvUtil.parse(isoCsv);
      expect(result.records.single.recordedAt, DateTime(2026, 9, 10, 21, 30));
      expect(result.records.single.isBackfilled, isTrue);
    });
  });

  group('导入 · 异常与容错', () {
    test('空文件给出提示且无记录', () {
      final result = CsvUtil.parse('');
      expect(result.records, isEmpty);
      expect(result.errors, isNotEmpty);
      expect(result.summary(), '没有可导入的数据');
    });

    test('BOM 与 CRLF 不影响解析', () {
      final csv = '\uFEFFID,Content,CreatedAt,UpdatedAt\r\n'
          'a1,hello,1787831939661,1787831939661\r\n';
      final result = CsvUtil.parse(csv);
      expect(result.records.single.id, 'a1');
      expect(result.records.single.content, 'hello');
    });

    test('缺 ID 时自动生成，缺内容时跳过并记错误', () {
      const csv = 'ID,Title,Content,Tags,CreatedAt,UpdatedAt\n'
          ',,有内容没ID,,1787831939661,1787831939661\n'
          'a2,,   ,,1787831939661,1787831939661\n';
      final result = CsvUtil.parse(csv);
      expect(result.records.length, 1);
      expect(result.records.single.id.isNotEmpty, isTrue);
      expect(result.skipped, 1);
      expect(result.errors.length, 1);
    });

    test('summary 文案包含条数与补记条数', () {
      final result = CsvUtil.parse(CsvUtil.export(<RecordEntity>[
        _record(
          id: 'a1',
          recordedAt: DateTime(2026, 9, 10, 12),
          createdAt: DateTime(2026, 9, 15, 12),
        ),
      ]));
      expect(result.summary(), contains('成功导入 1 条'));
      expect(result.summary(), contains('其中补记 1 条'));
    });

    test('导入的记录补记判定与 day_util 一致', () {
      final result = CsvUtil.parse(_legacyCsv);
      for (final record in result.records) {
        expect(record.isBackfilled, isFalse);
        expect(dayKey(record.recordedAt), dayKey(record.createdAt));
      }
    });
  });
}
