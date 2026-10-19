// 全文搜索的数据层回归测试。
//
// 搜索是「逐键触发、直接打库」的路径，最容易悄悄改错的三件事：
// 1. LIKE 通配符（% / _）必须转义 —— 否则搜「100%」会变成「100 开头的一切」；
// 2. 软删除的记录绝不能出现在结果里；
// 3. 结果按业务日期（recordedAt）倒序，和首页的排序口径一致。
//
// 用内存库跑真实的 DAO（VestigeDatabase 支持注入 executor，就是为这个留的口子）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';

final DateTime _day = DateTime(2026, 9, 15, 10, 0);

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;

  setUp(() {
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  Future<void> seed({
    required String id,
    String content = '1',
    String? title,
    List<String> tags = const <String>[],
    DateTime? recordedAt,
  }) =>
      repo.addRecord(
        id: id,
        content: content,
        title: title,
        tags: tags,
        recordedAt: recordedAt ?? _day,
      );

  test('正文包含匹配：中文片段也能命中', () async {
    await seed(id: 'a', content: '早上去跑了五公里');
    await seed(id: 'b', content: '1');

    final results = await repo.searchRecords('五公里');
    expect(results.map((r) => r.id), <String>['a']);
  });

  test('标题与标签同样可命中', () async {
    await seed(id: 'a', title: '保养记录', content: '1');
    await seed(id: 'b', content: '1', tags: <String>['咖啡']);
    await seed(id: 'c', content: '1');

    expect(
      (await repo.searchRecords('保养')).map((r) => r.id),
      <String>['a'],
    );
    expect(
      (await repo.searchRecords('咖啡')).map((r) => r.id),
      <String>['b'],
    );
  });

  test('软删除的记录不出现在结果里', () async {
    await seed(id: 'a', content: '删掉的一条咖啡');
    await seed(id: 'b', content: '活着的一条咖啡');
    await repo.deleteRecord('a');

    final results = await repo.searchRecords('咖啡');
    expect(results.map((r) => r.id), <String>['b']);
  });

  test('% 被转义：搜「100%」只命中字面量', () async {
    await seed(id: 'a', content: '进度 100%');
    await seed(id: 'b', content: '100 米跑完了');

    final results = await repo.searchRecords('100%');
    expect(results.map((r) => r.id), <String>['a']);
  });

  test('_ 被转义：搜「a_b」不匹配「axb」', () async {
    await seed(id: 'a', content: 'a_b');
    await seed(id: 'b', content: 'axb');

    final results = await repo.searchRecords('a_b');
    expect(results.map((r) => r.id), <String>['a']);
  });

  test('空串 / 纯空白直接返回空，不打全表', () async {
    await seed(id: 'a', content: '1');
    expect(await repo.searchRecords(''), isEmpty);
    expect(await repo.searchRecords('   '), isEmpty);
  });

  test('结果按业务日期倒序（和首页排序口径一致）', () async {
    await seed(id: 'old', content: '咖啡', recordedAt: DateTime(2026, 9, 1));
    await seed(id: 'new', content: '咖啡', recordedAt: DateTime(2026, 9, 20));

    final results = await repo.searchRecords('咖啡');
    expect(results.map((r) => r.id), <String>['new', 'old']);
  });
}
