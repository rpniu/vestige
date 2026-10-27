// 统计页「标签分布」的口径测试。
//
// 钉住三件事：
// 1. 跟着统计页的**年份**走（只看 recordedAt 的年份，补记算进归属那年）；
// 2. 一条记录带多个标签 → 每个标签**各记一次**（所以各项相加不等于总条数）；
// 3. 按次数降序，同次数按名称。
//
// 放在 provider 层测而不是页面里：年份口径是这个功能的唯一风险点，
// 而它在页面里看不出来（得切年份、数行数），在这里一行就能钉死。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/presentation/providers/records_provider.dart';

final int _year = DateTime.now().year;

RecordEntity _rec(String id, DateTime at, {List<String> tags = const <String>[]}) =>
    RecordEntity(
      bookId: 'default',
      id: id,
      title: null,
      content: 'c',
      tags: tags,
      recordedAt: at,
      createdAt: at,
      updatedAt: at,
      deleted: false,
    );

void main() {
  late ProviderContainer container;

  /// 起一个容器并**等第一帧数据**。
  ///
  /// 最后那句 await 不能省：`recordsProvider` 是 `StreamProvider`，
  /// 不等它 emit 就读下游 provider，`valueOrNull` 还是 null，
  /// 所有统计都会被算成「一条记录都没有」。
  Future<void> boot(List<RecordEntity> records) async {
    container = ProviderContainer(
      overrides: <Override>[
        recordsProvider.overrideWith((ref) => Stream.value(records)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(recordsProvider.future);
  }

  test('只统计选中年份，别的年份不计', () async {
    await boot(<RecordEntity>[
      _rec('a', DateTime(_year, 3, 1), tags: <String>['咖啡']),
      _rec('b', DateTime(_year - 1, 3, 1), tags: <String>['咖啡']),
      _rec('c', DateTime(_year - 1, 5, 1), tags: <String>['读书']),
    ]);

    // 默认是今年
    expect(container.read(tagStatsProvider), <({String tag, int count})>[
      (tag: '咖啡', count: 1),
    ]);

    container.read(selectedYearProvider.notifier).select(_year - 1);
    expect(
      container.read(tagStatsProvider).map((e) => e.tag).toSet(),
      <String>{'咖啡', '读书'},
      reason: '切到去年应该只剩去年那两个标签',
    );
  });

  test('一条记录带多个标签：每个标签各记一次', () async {
    await boot(<RecordEntity>[
      _rec('a', DateTime(_year, 3, 1), tags: <String>['咖啡', '读书']),
    ]);

    final stats = container.read(tagStatsProvider);
    expect(stats.length, 2);
    expect(
      stats.every((e) => e.count == 1),
      isTrue,
      reason: '一条记录同时贡献给两个标签，各算 1 次',
    );
  });

  test('按次数降序，同次数按名称升序', () async {
    await boot(<RecordEntity>[
      _rec('a', DateTime(_year, 1, 1), tags: <String>['b']),
      _rec('b', DateTime(_year, 1, 2), tags: <String>['a']),
      _rec('c', DateTime(_year, 1, 3), tags: <String>['a']),
      _rec('d', DateTime(_year, 1, 4), tags: <String>['c']),
      _rec('e', DateTime(_year, 1, 5), tags: <String>['c']),
      _rec('f', DateTime(_year, 1, 6), tags: <String>['c']),
    ]);

    expect(container.read(tagStatsProvider), <({String tag, int count})>[
      (tag: 'c', count: 3),
      (tag: 'a', count: 2),
      (tag: 'b', count: 1),
    ]);
  });

  test('记录没有标签 / 一条记录都没有 → 空列表', () async {
    await boot(<RecordEntity>[_rec('a', DateTime(_year, 1, 1))]);
    expect(container.read(tagStatsProvider), isEmpty);

    await boot(const <RecordEntity>[]);
    expect(container.read(tagStatsProvider), isEmpty);
  });
}
