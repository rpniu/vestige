// 撤销功能的回归测试。
//
// 盯的是「撤销 = 回到操作前的状态」这条**语义**，不是实现细节。
// 最容易写错的两处，用例里都单独钉了：
//
// 1. **用「反向操作」代替快照**：批量加标签 #A 的反向是「去掉 #A」，
//    但某条**本来就有** #A 的记录，加的时候是空操作，撤销却会把 #A 删掉。
// 2. **撤销「彻底删除」时只改 deleted 标志**：行都没了，必须把整行重新插回去。
//
// 直接构造 RecordActions（它是普通类，只是包了一层 repository），
// 不用起 Riverpod 容器 —— 撤销的语义全在数据层。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/undo_dao.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

void main() {
  late VestigeDatabase db;
  late RecordRepository repo;
  late RecordActions actions;

  setUp(() {
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
    actions = RecordActions(repo);
  });

  tearDown(() => db.close());

  Future<void> seed(
    String id, {
    List<String> tags = const <String>[],
    int day = 1,
  }) =>
      repo.addRecord(
        id: id,
        content: 'c-$id',
        tags: tags,
        recordedAt: DateTime(2026, 9, day, 9),
      );

  /// 等价于 UI 上点「撤销」：退掉历史里最新的一步。
  Future<int> undoLatest() async {
    final history = await actions.recentUndo();
    return actions.undoUpTo(history.first.id);
  }

  test('批量加标签 → 撤销：本来就有该标签的记录不会被误删', () async {
    await seed('a', tags: <String>['已有']);
    await seed('b');

    // 给两条都加「已有」+「新」—— 对 a 来说「已有」是空操作
    await actions.applyTags(<String>['a', 'b'], add: <String>['已有', '新']);
    expect((await repo.getRecordById('a'))!.tags, <String>['已有', '新']);
    expect((await repo.getRecordById('b'))!.tags, <String>['已有', '新']);

    await undoLatest();

    expect(
      (await repo.getRecordById('a'))!.tags,
      <String>['已有'],
      reason: '反向操作会把它删掉 —— 这正是必须存快照的原因',
    );
    expect((await repo.getRecordById('b'))!.tags, isEmpty);
  });

  test('批量去标签 → 撤销：被去掉的标签回来，没点到的保持原样', () async {
    await seed('a', tags: <String>['x', 'y']);
    await seed('b', tags: <String>['x']);

    await actions.applyTags(<String>['a', 'b'], remove: <String>['x']);
    expect((await repo.getRecordById('a'))!.tags, <String>['y']);

    await undoLatest();
    expect((await repo.getRecordById('a'))!.tags, <String>['x', 'y']);
    expect((await repo.getRecordById('b'))!.tags, <String>['x']);
  });

  test('批量平移日期 → 撤销：日期回到原样', () async {
    await seed('a', day: 10);
    final before = (await repo.getRecordById('a'))!.recordedAt;

    await actions.shiftDay(<String>['a'], 1);
    expect(
      (await repo.getRecordById('a'))!.recordedAt,
      before.add(const Duration(days: 1)),
    );

    await undoLatest();
    expect((await repo.getRecordById('a'))!.recordedAt, before);
  });

  test('移入回收站 → 撤销：记录回到列表，deletedAt 也清掉', () async {
    await seed('a');
    await actions.deleteRecords(<String>['a']);
    expect(await repo.getAllActiveRecordsSync(), isEmpty);

    await undoLatest();

    final back = (await repo.getRecordById('a'))!;
    expect(back.deleted, isFalse);
    expect(back.deletedAt, isNull);
    expect((await repo.getAllActiveRecordsSync()).length, 1);
  });

  test('彻底删除 → 撤销：整行被重新插回来', () async {
    await seed('a', tags: <String>['标签']);
    await repo.deleteRecord('a'); // 先进回收站
    await actions.hardDeleteRecords(<String>['a']);
    expect(await repo.getRecordById('a'), isNull, reason: '行已经没了');

    await undoLatest();

    final back = await repo.getRecordById('a');
    expect(back, isNotNull, reason: '快照带着完整字段，撤销要把整行插回去');
    expect(back!.tags, <String>['标签']);
    expect(
      back.deleted,
      isTrue,
      reason: '撤销的是「彻底删除」这一步，所以它该回到回收站状态',
    );
  });

  test('清空回收站 → 撤销：全部回来', () async {
    await seed('a');
    await seed('b');
    await repo.deleteRecords(<String>['a', 'b']);

    await actions.emptyTrash();
    expect(await repo.getDeletedRecords(), isEmpty);

    await undoLatest();
    expect((await repo.getDeletedRecords()).length, 2);
  });

  test('撤销到某一步：比它更新的步骤一起回滚', () async {
    await seed('a');
    await actions.applyTags(<String>['a'], add: <String>['x']);
    await actions.shiftDay(<String>['a'], 1);
    await actions.shiftDay(<String>['a'], 1);

    final history = await actions.recentUndo();
    expect(history.length, 3, reason: '三步都该记上');

    // history 是「新 → 旧」，last 是最早那一步；退到它之前 = 全退回
    await actions.undoUpTo(history.last.id);

    final r = (await repo.getRecordById('a'))!;
    expect(r.tags, isEmpty);
    expect(r.recordedAt, DateTime(2026, 9, 1, 9));
    expect(
      await actions.recentUndo(),
      isEmpty,
      reason: '被回滚掉的条目要从历史里清掉，它们描述的是已不存在的过去',
    );
  });

  test('撤销一步只消耗那一步的历史', () async {
    await seed('a');
    await actions.applyTags(<String>['a'], add: <String>['x']);
    await actions.shiftDay(<String>['a'], 1);
    expect((await actions.recentUndo()).length, 2);

    await undoLatest();

    final left = await actions.recentUndo();
    expect(left.length, 1);
    expect(left.first.label, '批量改标签', reason: '剩下的该是更早那一步');
  });

  test('一条都没改动就不记历史', () async {
    await seed('a', tags: <String>['x']);

    final changed = await actions.applyTags(<String>['a'], add: <String>['x']);

    expect(changed, 0);
    expect(
      await actions.recentUndo(),
      isEmpty,
      reason: '留一条「撤销了也没变化」的记录只会把列表弄脏',
    );
  });

  test('历史超过上限时丢掉最旧的', () async {
    await seed('a');
    for (var i = 0; i < kUndoHistoryLimit + 3; i++) {
      await actions.shiftDay(<String>['a'], 1);
    }
    expect((await actions.recentUndo()).length, kUndoHistoryLimit);
  });

  test('撤销一步会把该步涉及的记录都写回（多选场景）', () async {
    await seed('a', tags: <String>['x']);
    await seed('b', tags: <String>['x']);
    await seed('c', tags: <String>['x']);

    await actions.applyTags(
      <String>['a', 'b', 'c'],
      add: <String>['y'],
      remove: <String>['x'],
    );

    final restored = await undoLatest();

    expect(restored, 3, reason: '返回真正写回的条数');
    for (final id in <String>['a', 'b', 'c']) {
      expect((await repo.getRecordById(id))!.tags, <String>['x']);
    }
  });

  // ── 删除历史（单条 / 清空） ──────────────────────────────────────────

  test('删除单条历史：少一个回退点，记录和别的条目不受影响', () async {
    await seed('a');
    await actions.applyTags(<String>['a'], add: <String>['x']);
    await actions.shiftDay(<String>['a'], 1);

    final history = await actions.recentUndo(); // 新 → 旧
    await actions.deleteUndoEntry(history.last.id); // 删最旧那步

    final left = await actions.recentUndo();
    expect(left.length, 1);
    expect(left.first.label, '日期后移 1 天');
    expect(
      (await repo.getRecordById('a'))!.tags,
      <String>['x'],
      reason: '删历史 ≠ 删数据',
    );
  });

  test('删掉中间步骤后，回退更早一步仍取「最旧快照」，结果不变味', () async {
    await seed('a');
    await actions.applyTags(<String>['a'], add: <String>['x']); // 快照: 无标签
    await actions.applyTags(<String>['a'], add: <String>['y']); // 快照: [x]

    final history = await actions.recentUndo(); // [加y, 加x]
    await actions.deleteUndoEntry(history.first.id); // 抹掉「加y」这个回退点

    await actions.undoUpTo(history.last.id); // 退到「加x」之前

    expect(
      (await repo.getRecordById('a'))!.tags,
      isEmpty,
      reason: '回退取的是最旧快照，删掉更新的步骤不影响它',
    );
  });

  test('清空历史：全部抹掉，记录不动', () async {
    await seed('a');
    await actions.applyTags(<String>['a'], add: <String>['x']);
    await actions.shiftDay(<String>['a'], 1);

    await actions.clearUndoHistory();

    expect(await actions.recentUndo(), isEmpty);
    expect((await repo.getRecordById('a'))!.tags, <String>['x']);
  });
}
