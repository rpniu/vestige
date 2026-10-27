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

    final count = await actions.importRecords(<RecordEntity>[
      imported(id: 'a1', content: '文件里的内容', tags: const ['新']),
    ]);
    expect(count, 1);

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

  test('[C-002] 只新增（没有覆盖）时导入不产生空的回退点', () async {
    await actions.importRecords(<RecordEntity>[
      imported(id: 'brand-new', content: '全新的'),
    ]);
    expect(
      actions.lastUndoEntryId,
      isNull,
      reason: '没有既有记录被覆盖 → 快照为空 → 不应留下空历史',
    );
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
