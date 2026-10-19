// 数据层回归测试：批量平移日期现在是一条裸 SQL（`recorded_at = recorded_at + ?`），
// 这条路径的语义必须钉住 —— 改的时候最容易出的错是「时间单位搞错」
// （drift 存的是 Unix **秒**，不是毫秒）或者「delta 方向反了」。
//
// 用内存库跑真实的 DAO（VestigeDatabase 支持注入 executor，就是为这个留的口子）。

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

  Future<String> addAt(DateTime recordedAt, {String content = '1'}) async {
    await repo.addRecord(content: content, recordedAt: recordedAt);
    final all = await repo.getAllActiveRecordsSync();
    // getAllActiveSync 按业务日期倒序；这里只要那条 recordedAt 匹配的
    return all.firstWhere((r) => r.recordedAt == recordedAt).id;
  }

  test('平移一整天：recordedAt 整体 +1 天，createdAt 不动', () async {
    final id = await addAt(_day);
    final before = (await repo.getRecordById(id))!;

    await repo.shiftRecordedAt(<String>[id], const Duration(days: 1));

    final after = (await repo.getRecordById(id))!;
    // 加的是绝对时长，与 Dart 侧 recordedAt.add(Duration(days: 1)) 等价
    expect(after.recordedAt, before.recordedAt.add(const Duration(days: 1)));
    // 审计字段绝不因为改业务日期而变
    expect(after.createdAt, before.createdAt);
    // updatedAt 应该被刷新
    expect(
      after.updatedAt.isAfter(before.updatedAt) ||
          after.updatedAt.isAtSameMomentAs(before.updatedAt),
      isTrue,
    );
  });

  test('平移 -1 天同样成立', () async {
    final id = await addAt(_day);
    final before = (await repo.getRecordById(id))!;

    await repo.shiftRecordedAt(<String>[id], const Duration(days: -1));

    final after = (await repo.getRecordById(id))!;
    expect(after.recordedAt, before.recordedAt.subtract(const Duration(days: 1)));
  });

  test('批量：只动选中的那些，没选中的原样不动', () async {
    final a = await addAt(_day, content: 'a');
    final b = await addAt(DateTime(2026, 9, 14, 9), content: 'b');
    final c = await addAt(DateTime(2026, 9, 13, 9), content: 'c');
    final beforeB = (await repo.getRecordById(b))!;

    await repo.shiftRecordedAt(<String>[a, c], const Duration(days: 1));

    final afterA = (await repo.getRecordById(a))!;
    final afterB = (await repo.getRecordById(b))!;
    final afterC = (await repo.getRecordById(c))!;

    expect(afterA.recordedAt, _day.add(const Duration(days: 1)));
    expect(afterB.recordedAt, beforeB.recordedAt, reason: 'b 没被选中，不该动');
    expect(
      afterC.recordedAt,
      DateTime(2026, 9, 13, 9).add(const Duration(days: 1)),
    );
  });

  test('时间单位是秒不是毫秒：平移 1 天必须正好 86400 秒', () async {
    final id = await addAt(_day);
    final before = (await repo.getRecordById(id))!;

    await repo.shiftRecordedAt(<String>[id], const Duration(days: 1));

    final after = (await repo.getRecordById(id))!;
    final deltaSeconds =
        after.recordedAt.difference(before.recordedAt).inSeconds;
    expect(deltaSeconds, 86400, reason: '差 86400 秒 = 1 天；差 86400000 就是毫秒/秒搞错了');
  });

  test('空列表不会生成非法 SQL', () async {
    await expectLater(
      repo.shiftRecordedAt(const <String>[], const Duration(days: 1)),
      completes,
    );
  });

  test('不存在的 id 静默跳过，不影响其它记录', () async {
    final id = await addAt(_day);
    await expectLater(
      repo.shiftRecordedAt(<String>['not-a-real-id', id], const Duration(days: 1)),
      completes,
    );
    final after = (await repo.getRecordById(id))!;
    expect(after.recordedAt, _day.add(const Duration(days: 1)));
  });

  test('平移后同一天的两条记录仍然落在同一天（分组依据不变）', () async {
    final a = await addAt(_day, content: 'a');
    final b = await addAt(DateTime(2026, 9, 15, 23, 30), content: 'b');

    await repo.shiftRecordedAt(<String>[a, b], const Duration(days: 2));

    final afterA = (await repo.getRecordById(a))!;
    final afterB = (await repo.getRecordById(b))!;
    expect(afterA.recordedAt.day, 17);
    expect(afterB.recordedAt.day, 17);
  });
}
