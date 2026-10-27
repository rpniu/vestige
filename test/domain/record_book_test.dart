// 记录本的领域规则测试。
//
// 记录本的**存储**（表、外键、级联）在 `test/data/book_scope_test.dart` 里，
// 这里只管与存储无关的那点规则：默认本的标识、名字校验。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/record_book.dart';

void main() {
  group('默认记录本', () {
    test('id 是固定的字面量 default（迁移要拿它回填既有数据）', () {
      expect(kDefaultBookId, 'default');
      expect(isDefaultBook('default'), isTrue);
      expect(isDefaultBook('8a1f-4c2b'), isFalse);
    });

    test('默认名不用「默认」这种系统口径', () {
      expect(kDefaultBookName, isNot(contains('默认')));
      expect(kDefaultBookName, isNotEmpty);
    });
  });

  group('名字规范化', () {
    test('两侧空白被去掉', () {
      expect(normalizeBookName('  工作  '), '工作');
    });

    test('空 / 纯空白 → null', () {
      expect(normalizeBookName(''), isNull);
      expect(normalizeBookName('   '), isNull);
      expect(normalizeBookName('\t\n'), isNull);
    });

    test('超长 → null（不静默截断）', () {
      final atLimit = '本' * kMaxBookNameLength;
      expect(normalizeBookName(atLimit), atLimit, reason: '刚好到上限应可用');
      expect(normalizeBookName('$atLimit多'), isNull);
    });

    test('按字符数而不是字节数计长（中文名字不会被误判超长）', () {
      expect(normalizeBookName('一' * kMaxBookNameLength), isNotNull);
    });
  });
}
