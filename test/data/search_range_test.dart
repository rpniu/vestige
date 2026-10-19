// 搜索的日期范围（左闭右开）回归测试。
//
// 最容易错的是**边界**：8/31 那天的记录到底算不算在「8/1 – 8/31」里？
// 这里钉死：算。
//
// 约定：调用方（页面）从系统选择器拿到的是**闭区间**（含首尾两天），
// 所以它会把 end 往后推一天再传给仓储；仓储这边统一按 `[from, to)` 处理。
// 两边各自说清楚，才不会出现「差一天」这种最烦人的错。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;

  setUp(() {
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  Future<void> seed(
    String id,
    DateTime at, {
    String content = 'x',
  }) =>
      repo.addRecord(id: id, content: content, recordedAt: at);

  Future<List<String>> searchIds(
    String query, {
    DateTime? from,
    DateTime? to,
  }) async {
    final hits = await repo.searchRecords(query, from: from, to: to);
    return hits.map((RecordEntity r) => r.id).toList();
  }

  test('关键词 + 范围：两个条件都得满足', () async {
    await seed('in', DateTime(2026, 8, 15, 10), content: '咖啡');
    await seed('outOfRange', DateTime(2026, 9, 15, 10), content: '咖啡');
    await seed('noKeyword', DateTime(2026, 8, 16, 10), content: '茶');

    expect(
      await searchIds('咖啡', from: DateTime(2026, 8, 1), to: DateTime(2026, 9, 1)),
      <String>['in'],
    );
  });

  test('边界：8/1 零点与 8/31 深夜都算在内，9/1 零点整不算', () async {
    await seed('first', DateTime(2026, 8, 1));
    await seed('last', DateTime(2026, 8, 31, 23, 59));
    await seed('next', DateTime(2026, 9, 1));

    expect(
      await searchIds('', from: DateTime(2026, 8, 1), to: DateTime(2026, 9, 1)),
      <String>['last', 'first'],
      reason: '左闭右开：[8/1 00:00, 9/1 00:00)',
    );
  });

  test('只有范围、没有关键词 = 浏览这段时间的全部记录', () async {
    await seed('a', DateTime(2026, 8, 5));
    await seed('b', DateTime(2026, 8, 6));
    await seed('c', DateTime(2026, 10, 6));

    expect(
      await searchIds('', from: DateTime(2026, 8, 1), to: DateTime(2026, 9, 1)),
      <String>['b', 'a'],
    );
  });

  test('既没关键词也没范围：返回空，不把全库拖出来', () async {
    await seed('a', DateTime(2026, 8, 5));
    expect(await repo.searchRecords(''), isEmpty);
  });

  test('只给一边（单边开口）也能用', () async {
    await seed('a', DateTime(2026, 8, 5));
    await seed('b', DateTime(2026, 10, 5));

    expect(await searchIds('', from: DateTime(2026, 9, 1)), <String>['b']);
    expect(await searchIds('', to: DateTime(2026, 9, 1)), <String>['a']);
  });

  test('软删的记录不会被搜出来', () async {
    await seed('gone', DateTime(2026, 8, 5));
    await repo.deleteRecord('gone');

    expect(
      await searchIds('', from: DateTime(2026, 8, 1), to: DateTime(2026, 9, 1)),
      isEmpty,
    );
  });

  test('范围外的标签命中也不算', () async {
    await seed('tagged', DateTime(2026, 7, 5));
    await repo.applyTags(<String>['tagged'], add: <String>['咖啡']);

    expect(
      await searchIds('咖啡', from: DateTime(2026, 8, 1), to: DateTime(2026, 9, 1)),
      isEmpty,
    );
  });
}
