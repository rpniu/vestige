import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/csv_util.dart';

/// 落盘级别的验证：导出的 CSV 写成文件后，头三个字节必须是 UTF-8 BOM
/// （EF BB BF）——这正是 Windows 上 Excel 不乱码的前提。
/// 这里刻意走 `File.writeAsString`，与 `services/csv_file_native.dart` 的真实路径一致。
void main() {
  test('导出的 CSV 写成文件后带 UTF-8 BOM 字节', () async {
    final csv = CsvUtil.export(<RecordEntity>[
      RecordEntity(
        id: 'a1',
        title: '中文标题',
        content: '中文内容',
        tags: const <String>['运动'],
        recordedAt: DateTime(2026, 9, 10, 21, 30),
        createdAt: DateTime(2026, 9, 15, 11),
        updatedAt: DateTime(2026, 9, 15, 11),
        deleted: false,
      ),
    ]);

    final file = File(
      '${Directory.systemTemp.path}/vestige_bom_check_'
      '${DateTime.now().microsecondsSinceEpoch}.csv',
    );
    await file.writeAsString(csv);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final bytes = await file.readAsBytes();
    expect(
      bytes.take(3).toList(),
      <int>[0xEF, 0xBB, 0xBF],
      reason: '文件开头必须是 UTF-8 BOM，否则 Windows Excel 会按 GBK 打开导致中文乱码',
    );

    // 注意：Dart 的 `utf8.decode` 会**主动剥掉**开头的 BOM，
    // 所以真正的证据是上面的原始字节，而不是解码后的字符串。
    final text = utf8.decode(bytes);
    expect(
      text.startsWith(CsvUtil.bom),
      isFalse,
      reason: 'Utf8Decoder 会吃掉前导 BOM（这也是导入不需要额外去 BOM 的原因）',
    );

    final parsed = CsvUtil.parse(text);
    expect(parsed.records.single.title, '中文标题');
    expect(parsed.records.single.content, '中文内容');
    expect(parsed.records.single.tags, <String>['运动']);

    // 把 BOM 字符留在字符串里（例如从别处拼出来的文本）也要能解析
    final parsedWithBom = CsvUtil.parse('${CsvUtil.bom}$text');
    expect(parsedWithBom.records.single.title, '中文标题');
  });
}
