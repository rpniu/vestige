// 数据层回归测试：批量打标签 / 去标签。
//
// 这条路径的关键语义，改的时候最容易错的就是这几条：
// - 「加上」是**并集**（已有的保留、新加的补在后面），不是覆盖；
// - 「去掉」是差集，只删指定的那些；
// - 只碰传进来的那些 id，没选的记录原样不动；
// - 标签没变化的记录**不写库** —— 否则 `updatedAt` 会被无谓推新，
//   而那个字段是回收站的排序依据。
//
// 用内存库跑真实的 DAO（与 record_dao_shift_test.dart 同一套做法）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';

/// 固定时刻，避免跨越午夜时断言漂移。
final DateTime _day = DateTime(2026, 9, 15, 10, 0);

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;

  setUp(() {
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  /// 插一条带标签的记录，返回它的 id。用 [content] 区分不同记录。
  Future<String> addWithTags(
    List<String> tags, {
    String content = 'x',
  }) async {
    await repo.addRecord(content: content, tags: tags, recordedAt: _day);
    final all = await repo.getAllActiveRecordsSync();
    return all.firstWhere((r) => r.content == content).id;
  }

  test('加标签是并集：已有标签保留，新标签补在后面', () async {
    final id = await addWithTags(<String>['运动']);

    await repo.applyTags(<String>[id], add: <String>['读书']);

    expect((await repo.getRecordById(id))!.tags, <String>['运动', '读书']);
  });

  test('加本来就在的标签：不重复，也不写库', () async {
    final id = await addWithTags(<String>['运动']);
    final before = (await repo.getRecordById(id))!;

    final changed = await repo.applyTags(<String>[id], add: <String>['运动']);

    expect(changed, 0, reason: '标签没变化，不算改动');
    final after = (await repo.getRecordById(id))!;
    expect(after.tags, <String>['运动']);
    expect(after.updatedAt, before.updatedAt, reason: '空操作不该推新 updatedAt');
  });

  test('去标签是差集，没点到的标签留着', () async {
    final id = await addWithTags(<String>['运动', '读书', '旅行']);

    await repo.applyTags(<String>[id], remove: <String>['读书']);

    expect((await repo.getRecordById(id))!.tags, <String>['运动', '旅行']);
  });

  test('只碰选中的记录，没选的原样不动', () async {
    final a = await addWithTags(<String>['运动'], content: 'a');
    final b = await addWithTags(<String>['读书'], content: 'b');

    await repo.applyTags(<String>[a], add: <String>['旅行']);

    expect((await repo.getRecordById(a))!.tags, <String>['运动', '旅行']);
    expect((await repo.getRecordById(b))!.tags, <String>['读书']);
  });

  test('返回值是**真正被改动**的条数', () async {
    final a = await addWithTags(<String>['运动'], content: 'a');
    final b = await addWithTags(<String>['运动'], content: 'b');

    // 两条都已经有「运动」了 → 一条都没改
    expect(
      await repo.applyTags(<String>[a, b], add: <String>['运动']),
      0,
    );
    // 加一个新标签 → 两条都改
    expect(
      await repo.applyTags(<String>[a, b], add: <String>['旅行']),
      2,
    );
  });

  test('同时给 add 和 remove：先加后减', () async {
    final id = await addWithTags(<String>['运动']);

    await repo.applyTags(
      <String>[id],
      add: <String>['读书'],
      remove: <String>['运动'],
    );

    expect((await repo.getRecordById(id))!.tags, <String>['读书']);
  });

  test('空 ids、以及 add/remove 都空，都是空操作', () async {
    final id = await addWithTags(<String>['运动']);

    expect(await repo.applyTags(<String>[], add: <String>['x']), 0);
    expect(await repo.applyTags(<String>[id]), 0);

    expect((await repo.getRecordById(id))!.tags, <String>['运动']);
  });
}
