// 导入时「文件里的记录本 → 本库哪一本」的裁决规则。
//
// 这条规则有两个使用者（导入预览、真正写库），所以单独钉住：
// 预览说会写进学习本，实际就必须写进学习本。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/book_plan.dart';
import 'package:vestige/domain/record_book.dart';

void main() {
  List<BookPlanEntry> plan({
    required Map<String, int> counts,
    Map<String, String> names = const <String, String>{},
    Map<String, String> idNames = const <String, String>{},
    Map<String, String> existingNames = const <String, String>{},
  }) =>
      planBooks(
        counts: counts,
        names: names,
        existingIdNames: idNames,
        existingNames: existingNames,
      );

  test('本库已有这个 id → 归入它，名字用库里的（文件里的可能已过时）', () {
    final result = plan(
      counts: <String, int>{'bk-1': 3},
      names: const <String, String>{'bk-1': '旧名字'},
      idNames: const <String, String>{'bk-1': '新名字'},
      existingNames: const <String, String>{'新名字': 'bk-1'},
    ).single;

    expect(result.target, BookTarget.existing);
    expect(result.targetBookId, 'bk-1');
    expect(result.label, '新名字');
    expect(result.count, 3);
  });

  test('id 不认识但库里有同名本 → 归入同名本（跨设备场景）', () {
    final result = plan(
      counts: <String, int>{'other-device-uuid': 2},
      names: const <String, String>{'other-device-uuid': '学习'},
      existingNames: const <String, String>{'学习': 'local-book'},
    ).single;

    expect(result.target, BookTarget.existing);
    expect(result.targetBookId, 'local-book');
    expect(result.label, '学习');
  });

  test('id 与名字都不认识 → 新建一本', () {
    final result = plan(
      counts: <String, int>{'other-device-uuid': 5},
      names: const <String, String>{'other-device-uuid': '旅行'},
      existingNames: const <String, String>{'学习': 'local-book'},
    ).single;

    expect(result.target, BookTarget.create);
    expect(result.newName, '旅行');
    expect(result.note, '将新建记录本');
  });

  test('名字缺失 → 归入默认本，而不是丢记录', () {
    final result = plan(
      counts: <String, int>{'unknown': 4},
      existingNames: const <String, String>{'学习': 'local-book'},
    ).single;

    expect(result.target, BookTarget.fallback);
    expect(result.targetBookId, kDefaultBookId);
    expect(result.label, kDefaultBookName);
    expect(result.count, 4);
  });

  test('名字超长（不合法）→ 也归入默认本', () {
    final result = plan(
      counts: <String, int>{'unknown': 1},
      names: <String, String>{'unknown': 'x' * (kMaxBookNameLength + 1)},
    ).single;

    expect(result.target, BookTarget.fallback);
    expect(result.targetBookId, kDefaultBookId);
  });

  test('同一份文件里的多本各算各的，顺序与文件里首次出现的顺序一致', () {
    final result = plan(
      counts: <String, int>{'a': 1, 'b': 2, 'c': 3},
      names: const <String, String>{'a': '学习', 'b': '工作'},
      idNames: const <String, String>{'default': '我的记录本'},
      existingNames: const <String, String>{'学习': 'a'},
    );

    expect(result.map((e) => e.csvBookId), <String>['a', 'b', 'c']);
    expect(result[0].target, BookTarget.existing);
    expect(result[1].target, BookTarget.create);
    expect(result[2].target, BookTarget.fallback);
  });
}
