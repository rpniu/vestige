// CSV 字节流解码的回归测试。
//
// 这段逻辑决定「用户导入时看到的是正常文本还是一堆乱码」，而且要在预览里
// **如实**告诉他编码可能不对 —— 说错了，用户会跑去改一个本来没问题的文件。
//
// 它原来埋在 `profile_screen` 的私有方法里（815 行的页面、零测试），
// 2026-09-23 搬到 [CsvUtil.decodeBytes] 就是为了能被这样钉住。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/csv_util.dart';

void main() {
  test('干净的 UTF-8：原样解出，标记为没问题', () {
    final (String text, bool isUtf8) =
        CsvUtil.decodeBytes(utf8.encode('ID,Content\n1,咖啡'));

    expect(text, 'ID,Content\n1,咖啡');
    expect(isUtf8, isTrue);
  });

  test('带 BOM 的 UTF-8 也算干净；BOM 在解码时已被剥掉', () {
    final (String text, bool isUtf8) =
        CsvUtil.decodeBytes(utf8.encode('${CsvUtil.bom}ID,Content\n1,x'));

    expect(isUtf8, isTrue);
    // 实测确认：Dart 的 `utf8.decode` **自己会剥掉**开头的 BOM，
    // 所以到这里已经看不见它了。CsvUtil.parse 里那句剥 BOM 是给
    // 「没有表头的裸数据」等路径兜底的，两层不冲突。
    expect(text.startsWith(CsvUtil.bom), isFalse);
    expect(text, 'ID,Content\n1,x');
  });

  test('非 UTF-8 字节（如 GBK）：不抛异常，退回容错模式并标记出来', () {
    // 0xBF 0xA7 是「咖」的 GBK 编码：0xBF 是续接字节、前面没有前导字节，
    // 严格 UTF-8 解析必然失败 —— 正是 Excel / Windows 导出 CSV 的常见情形。
    final (String text, bool isUtf8) = CsvUtil.decodeBytes(<int>[0xBF, 0xA7]);

    expect(isUtf8, isFalse, reason: '必须标记出来，界面才能提示「编码可能不对」');
    expect(text, isNotEmpty, reason: '容错模式要给出文本，而不是把导入整个搞崩');
    expect(
      text.contains('\uFFFD'),
      isTrue,
      reason: '会变成替换字符（也就是用户眼里的乱码）—— 这正是不提示不行的原因',
    );
  });

  test('纯 ASCII 永远解得出，且算干净', () {
    final (String text, bool isUtf8) = CsvUtil.decodeBytes(ascii.encode('a,b,c'));

    expect(text, 'a,b,c');
    expect(isUtf8, isTrue);
  });

  test('空字节流：空文本，不算异常', () {
    final (String text, bool isUtf8) = CsvUtil.decodeBytes(const <int>[]);

    expect(text, isEmpty);
    expect(isUtf8, isTrue);
  });
}
