// 2026-10-27 代码审查修复项的回归测试（数据层）。
//
// 每个 testWidgets/test 的标题里都带了审查编号，方便对照本地的审查报告
// （`temp/review/code-review-2026-10-27.md`，按规定不入库）：
// - C-002 CSV 导入可撤销
// - C-003 quickAddToday 返回 id，撤销按 id 精确命中
// - M-005 批量彻底删除的空列表守卫
// - M-007 lastUndoEntryId 反映「这次到底有没有记历史」
// - 新发现：撤销「彻底删除」必须连时长一起还原

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

  /// 构造一条导入用的记录（字段与 CSV 解析产物一致）。
  RecordEntity imported({
    required String id,
    required String content,
    List<String> tags = const <String>[],
    int? durationSec,
    DateTime? recordedAt,
  }) {
    final now = recordedAt ?? DateTime(2026, 10, 1, 9);
    return RecordEntity(
      bookId: 'default',
      id: id,
      title: null,
      content: content,
      tags: tags,
      recordedAt: now,
      createdAt: now,
      updatedAt: now,
      deleted: false,
      durationS: durationSec,
    );
  }

  test('[C-002] CSV 导入覆盖既有记录后可撤销，内容回到导入前', () async {
    await repo.addRecord(id: 'a1', content: '导入前的内容', tags: const ['旧']);

    final outcome = await actions.importRecords(<RecordEntity>[
      imported(id: 'a1', content: '文件里的内容', tags: const ['新']),
    ]);
    expect(outcome.written, 1);
    expect(outcome.overwritten, 1);
    expect(outcome.added, 0);

    final overwritten = await repo.getRecordById('a1');
    expect(overwritten!.content, '文件里的内容');
    expect(overwritten.tags, <String>['新']);

    // 导入必须是可撤销的
    expect(
      actions.lastUndoEntryId,
      isNotNull,
      reason: '导入产生了覆盖，就必须留下回退点',
    );
    await actions.undoUpTo(actions.lastUndoEntryId!);

    final restored = await repo.getRecordById('a1');
    expect(restored!.content, '导入前的内容', reason: '撤销应还原被覆盖的内容');
    expect(restored.tags, <String>['旧']);
  });

  test('[C-002/v8] 纯新增的导入同样留回退点，撤销后新记录被删掉', () async {
    final outcome = await actions.importRecords(<RecordEntity>[
      imported(id: 'brand-new', content: '全新的'),
    ]);
    expect(outcome.added, 1);
    expect(outcome.overwritten, 0);
    expect(await repo.getRecordById('brand-new'), isNotNull);

    expect(
      actions.lastUndoEntryId,
      isNotNull,
      reason: 'v8 起纯新增也能撤销：快照为空不再等于「没有可回滚的内容」',
    );
    final undo = await actions.undoUpTo(actions.lastUndoEntryId!);

    expect(undo.removed, 1, reason: '撤销新增只能靠删除，写回表达不了');
    expect(undo.restored, 0);
    expect(
      await repo.getRecordById('brand-new'),
      isNull,
      reason: '撤销导入要把这条行彻底删掉，而不是只移进回收站',
    );
  });

  test('[v8] 覆盖 + 新增混合：两条路径同时生效', () async {
    await repo.addRecord(id: 'old', content: '库里原有的');

    await actions.importRecords(<RecordEntity>[
      imported(id: 'old', content: '文件覆盖的'),
      imported(id: 'new', content: '文件新增的'),
    ]);

    final undo = await actions.undoUpTo(actions.lastUndoEntryId!);

    expect(undo.restored, 1);
    expect(undo.removed, 1);
    expect((await repo.getRecordById('old'))!.content, '库里原有的');
    expect(await repo.getRecordById('new'), isNull);
  });

  test('[v8] 导入后又编辑过的新增行，撤销导入时一样被删掉', () async {
    await actions.importRecords(<RecordEntity>[
      imported(id: 'n1', content: '导入的内容'),
    ]);
    // 导入之后编辑它：编辑这一步的快照里含这一行。
    await actions.applyTags(<String>['n1'], add: <String>['新标签']);
    expect((await repo.getRecordById('n1'))!.tags, <String>['新标签']);

    // 退到导入之前 → 编辑与导入两步一起回滚。
    final history = await actions.recentUndo();
    final importStep = history.last;
    final undo = await actions.undoUpTo(importStep.id);

    expect(
      await repo.getRecordById('n1'),
      isNull,
      reason: '删除必须写在整行写回之后：写回会把编辑快照里的这一行重新插进来',
    );
    expect(undo.removed, 1);
    expect(undo.restored, 0);
  });

  test('[v8] 导入的历史条目只在「影响 N 条」里也能看出新增', () async {
    await actions.importRecords(<RecordEntity>[
      imported(id: 'only-new', content: 'x'),
    ]);
    final entry = (await actions.recentUndo()).first;
    expect(
      entry.recordCount,
      1,
      reason: '纯新增若不并入条数，历史里会显示「影响 0 条」',
    );
    expect(entry.insertedRecordIds, <String>['only-new']);
  });

  test('[C-003] quickAddToday 返回的 id 就是落库那一行', () async {
    final id = await actions.quickAddToday(content: '速记');
    final row = await repo.getRecordById(id);
    expect(row, isNotNull);
    expect(row!.content, '速记');

    // 按 id 撤销：只该删掉这一条，与「今天还有别的记录」无关
    await actions.deleteRecord(id);
    expect(await repo.getRecordById(id), isNotNull, reason: '软删的行仍在库里');
    expect((await repo.getRecordById(id))!.deleted, isTrue);
    expect(await repo.getAllActiveRecordsSync(), isEmpty);
  });

  test('[M-005] hardDeleteMany 传空列表直接返回，不抛 IN () 语法错误', () async {
    await expectLater(repo.hardDeleteRecords(const <String>[]), completes);
  });

  test('[M-007] 有快照时 lastUndoEntryId 非空；空快照时为空', () async {
    await repo.addRecord(id: 'a1', content: 'x');

    await actions.deleteRecords(<String>['a1']);
    expect(actions.lastUndoEntryId, isNotNull);

    // 已不存在的 id：快照为空 → 不该记历史
    await actions.deleteRecords(<String>['ghost']);
    expect(
      actions.lastUndoEntryId,
      isNull,
      reason: '没有命中任何记录时，撤销按钮不该出现（否则会退掉上一步）',
    );
  });

  test('撤销「彻底删除」要连时长一起还原（修复列表漏列 durationS）', () async {
    await repo.addRecord(id: 'b1', content: '带时长的记录', durationSec: 2700);

    await actions.hardDeleteRecords(<String>['b1']);
    expect(await repo.getRecordById('b1'), isNull);

    await actions.undoUpTo(actions.lastUndoEntryId!);
    final restored = await repo.getRecordById('b1');
    expect(restored, isNotNull);
    expect(
      restored!.durationS,
      2700,
      reason: 'restoreRows 的列清单漏了 durationS 时，这里会是 null（真实丢数据）',
    );
  });
}
