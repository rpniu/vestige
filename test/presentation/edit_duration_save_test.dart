// 编辑页「时长三态」在**保存之后**仍然成立的回归测试（2026-10-28 审查 m-00x）。
//
// 时长写库是三态：设值 / 清空 / 不动。区分「清空」和「本来就没有」靠的是
// `EditRecordState.originalDurationSec`（打开页面时库里的值）。
// 它原先在保存成功后**没有跟着刷新**，于是：
//   设时长 → 保存 → 清空 → 保存
// 第二轮的清空会被判成「本来就没有」→ 写库时走 absent → 库里留着旧值，
// 界面却显示未设置。页面保存后会 pop，所以正常操作路径碰不到；
// 但 controller 是公开 API，且「保存后停留继续编辑」是随时可能加上的交互。
//
// 这里从 provider 层直接驱动 controller，不经过页面。

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
  late VestigeDatabase db;
  late RecordRepository repo;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    db = VestigeDatabase(NativeDatabase.memory());
    repo = RecordRepository(db.recordDao);
  });

  tearDown(() => db.close());

  /// 起一个容器并订阅 provider，避免 autoDispose 在两次读之间就把 controller 丢掉。
  Future<(ProviderContainer, ProviderSubscription<Object?>)> boot(
    String key,
  ) async {
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    final provider = editRecordProvider(key);
    final sub = container.listen(provider, (_, _) {});
    await container.read(provider.future);
    return (container, sub);
  }

  test('既有记录：设时长 → 保存 → 清空 → 保存，库里必须变成 null', () async {
    await repo.addRecord(content: '一条记录');
    final id = (await repo.getAllActiveRecordsSync()).single.id;

    final (container, _) = await boot(id);
    final ctrl = container.read(editRecordProvider(id).notifier);

    ctrl.setDurationSec(600);
    expect(await ctrl.save(), isTrue);
    expect((await repo.getRecordById(id))!.durationS, 600);

    // 保存后「原值」必须对齐到刚落库的 600，否则下面的清空会被当成空操作
    expect(
      container.read(editRecordProvider(id)).valueOrNull!.originalDurationSec,
      600,
    );

    ctrl.setDurationSec(null); // = 用户点了「清除」
    expect(await ctrl.save(), isTrue);
    expect(
      (await repo.getRecordById(id))!.durationS,
      isNull,
      reason: '清空必须真的写进库里，不能只改界面',
    );
  });

  test('新建记录：带时长落库后再清空，同样要能清掉', () async {
    const key = kNewRecordId;
    final (container, _) = await boot(key);
    final ctrl = container.read(editRecordProvider(key).notifier);

    ctrl.setContent('新的一条');
    ctrl.setDurationSec(90);
    expect(await ctrl.save(), isTrue);

    final saved = (await repo.getAllActiveRecordsSync()).single;
    expect(saved.durationS, 90);
    expect(
      container.read(editRecordProvider(key)).valueOrNull!.originalDurationSec,
      90,
      reason: '落库后原值要跟着走，否则下一次清空会失效',
    );

    ctrl.setDurationSec(null);
    expect(await ctrl.save(), isTrue);
    expect((await repo.getRecordById(saved.id))!.durationS, isNull);
  });
}
