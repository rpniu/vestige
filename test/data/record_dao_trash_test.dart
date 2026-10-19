// 回收站时间戳的回归测试（v3 加的 deletedAt）。
//
// 最容易出的错是「恢复时忘了把 deletedAt 清掉」——
// 那样「恢复 → 再删」会沿用上一次的删除时刻，回收站里看到的删除时间就是假的。
//
// 用内存库跑真实的 DAO（与 record_dao_shift_test.dart 同一套做法）。

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

  Future<String> addOne() async {
    await repo.addRecord(
      id: 'r1',
      content: 'x',
      recordedAt: DateTime(2026, 9, 1, 9),
    );
    return 'r1';
  }

  /// drift 把 dateTime 存成 Unix **秒**（毫秒会被截断），所以比较前先抹掉毫秒。
  DateTime floorToSecond(DateTime t) =>
      DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch ~/ 1000 * 1000);

  test('新增的记录 deletedAt 是 null', () async {
    final id = await addOne();
    expect((await repo.getRecordById(id))!.deletedAt, isNull);
  });

  test('软删除会记下删除时刻', () async {
    final id = await addOne();
    final before = DateTime.now();
    await repo.deleteRecord(id);
    final after = DateTime.now();

    final r = (await repo.getRecordById(id))!;
    expect(r.deleted, isTrue);
    expect(r.deletedAt, isNotNull);
    expect(r.deletedAt!.isBefore(floorToSecond(before)), isFalse);
    expect(r.deletedAt!.isAfter(after), isFalse);
  });

  test('批量软删除同样记时刻', () async {
    final id = await addOne();
    await repo.deleteRecords(<String>[id]);
    expect((await repo.getRecordById(id))!.deletedAt, isNotNull);
  });

  test('恢复会把 deletedAt 清回 null —— 再删要重新计时', () async {
    final id = await addOne();
    await repo.deleteRecord(id);
    await repo.restoreRecord(id);

    final r = (await repo.getRecordById(id))!;
    expect(r.deleted, isFalse);
    expect(
      r.deletedAt,
      isNull,
      reason: '不清的话，「恢复 → 再删」会沿用旧的删除时刻，回收站里的删除时间就是假的',
    );
  });

  test('批量恢复同样清掉', () async {
    final id = await addOne();
    await repo.deleteRecords(<String>[id]);
    await repo.restoreRecords(<String>[id]);
    expect((await repo.getRecordById(id))!.deletedAt, isNull);
  });

  test('空 id 列表的批量软删 / 恢复不报错（IN () 是非法 SQL）', () async {
    await repo.deleteRecords(const <String>[]);
    await repo.restoreRecords(const <String>[]);
  });
}
