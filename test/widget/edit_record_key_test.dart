// 编辑页 family key 的格式测试。
//
// 背景（2026-10-22 真机 bug）：计时器「停止并记录」只带时长、不带日期，
// 而旧实现**只有日期非空时才写时长段** —— key 退化成 `new`，时长整段丢失。
// 现在格式固定为两段 `new@<日期>@<秒>`，空段保留。

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/repositories/record_repository.dart';
import 'package:vestige/presentation/providers/core_providers.dart';
import 'package:vestige/presentation/providers/edit_record_provider.dart';
import 'package:vestige/presentation/providers/theme_provider.dart';

void main() {
  group('editRecordKey', () {
    test('都不给 → 干脆的 new', () {
      expect(editRecordKey(), kNewRecordId);
      expect(
        editRecordKey(initialDay: null, initialDurationSec: null),
        kNewRecordId,
      );
    });

    test('只给日期 → new@日期@（时长段留空）', () {
      expect(
        editRecordKey(initialDay: DateTime(2026, 10, 22)),
        'new@2026-10-22@',
      );
    });

    test('只给时长（计时器入口）→ 日期段留空、时长段保留', () {
      expect(editRecordKey(initialDurationSec: 2700), 'new@@2700');
    });

    test('日期 + 时长都给', () {
      expect(
        editRecordKey(
          initialDay: DateTime(2026, 9, 14),
          initialDurationSec: 45,
        ),
        'new@2026-09-14@45',
      );
    });

    test('编辑既有记录 → 直接用 id，不编码任何参数', () {
      expect(
        editRecordKey(recordId: 'abc-123', initialDurationSec: 60),
        'abc-123',
      );
    });

    test('时长段不会被日期段吞掉：两段都非空时 @ 恰好两个', () {
      final key = editRecordKey(
        initialDay: DateTime(2026, 1, 2),
        initialDurationSec: 90,
      );
      expect('@'.allMatches(key).length, 2);
      expect(key.split('@'), <String>['new', '2026-01-02', '90']);
    });
  });

  group('计时器入口 → 记录真的带上了时长', () {
    late VestigeDatabase db;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      db = VestigeDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('`new@@2700` 的初始状态：时长为 2700 秒、业务日期是今天', () async {
      final state = await container
          .read(editRecordProvider(editRecordKey(initialDurationSec: 2700)).future);

      expect(state.durationSec, 2700);
      expect(state.isNew, isTrue);
      expect(state.isRecordedToday, isTrue, reason: '没给日期段就该落在今天');
    });

    test('填内容并保存 → 库里这条记录的 durationS 就是 2700', () async {
      final key = editRecordKey(initialDurationSec: 2700);
      final notifier = container.read(editRecordProvider(key).notifier);
      await container.read(editRecordProvider(key).future);
      notifier.setContent('计时记的一条');

      expect(await notifier.save(), isTrue);

      final saved = await RecordRepository(db.recordDao).getAllActiveRecordsSync();
      expect(saved, hasLength(1));
      expect(saved.single.durationS, 2700, reason: '时长必须和记录一起落库');
      expect(saved.single.content, '计时记的一条');
    });
  });
}
