// 记录快照的编解码测试。
//
// 快照是撤销功能的地基：它读不出来，这一步就再也撤不回了。
// 所以既测正常往返，也测**坏数据不炸** —— 历史里混进一条坏的，
// 不该让整个「操作历史」打不开。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/domain/record_snapshot.dart';

RecordEntity _rec(
  String id, {
  String? title,
  List<String> tags = const <String>[],
  bool deleted = false,
  DateTime? deletedAt,
}) {
  final at = DateTime(2026, 9, 15, 10, 30);
  return RecordEntity(
    bookId: 'default',
    id: id,
    title: title,
    content: '内容 $id',
    tags: tags,
    recordedAt: at,
    createdAt: at,
    updatedAt: at,
    deleted: deleted,
    deletedAt: deletedAt,
  );
}

void main() {
  test('往返：所有字段原样回来', () {
    final source = <RecordEntity>[
      _rec(
        'a',
        title: '标题',
        tags: <String>['x', 'y'],
        deleted: true,
        deletedAt: DateTime(2026, 9, 20, 8),
      ),
      _rec('b'),
    ];

    final back = RecordSnapshot.decode(RecordSnapshot.encode(source));

    expect(back.length, 2);
    expect(back.first.id, 'a');
    expect(back.first.title, '标题');
    expect(back.first.content, '内容 a');
    expect(back.first.tags, <String>['x', 'y']);
    expect(back.first.recordedAt, DateTime(2026, 9, 15, 10, 30));
    expect(back.first.deleted, isTrue);
    expect(back.first.deletedAt, DateTime(2026, 9, 20, 8));
    expect(back.last.title, isNull);
    expect(back.last.tags, isEmpty);
    expect(back.last.deleted, isFalse);
    expect(back.last.deletedAt, isNull);
  });

  test('空列表往返', () {
    expect(RecordSnapshot.decode(RecordSnapshot.encode(const <RecordEntity>[])),
        isEmpty);
  });

  test('坏 JSON → 空列表，不抛', () {
    expect(RecordSnapshot.decode('这不是 json'), isEmpty);
    expect(RecordSnapshot.decode('{"v":1}'), isEmpty);
    expect(RecordSnapshot.decode('[]'), isEmpty);
  });

  test('单条坏数据只丢那一条，其余照常解析', () {
    // 第二条缺 content（NOT NULL 列）→ 只该丢它
    const source = '''
{"v":1,"rows":[
  {"id":"good","title":null,"content":"c","tags":["t"],
   "recordedAt":"2026-09-15T10:30:00.000","createdAt":"2026-09-15T10:30:00.000",
   "updatedAt":"2026-09-15T10:30:00.000","deleted":false,"deletedAt":null},
  {"id":"broken","title":null,"tags":[],
   "recordedAt":"2026-09-15T10:30:00.000","createdAt":"2026-09-15T10:30:00.000",
   "updatedAt":"2026-09-15T10:30:00.000","deleted":false,"deletedAt":null},
  {"id":"alsoGood","title":null,"content":"c2","tags":[],
   "recordedAt":"2026-09-15T10:30:00.000","createdAt":"2026-09-15T10:30:00.000",
   "updatedAt":"2026-09-15T10:30:00.000","deleted":false,"deletedAt":null}
]}
''';

    final back = RecordSnapshot.decode(source);

    expect(back.map((RecordEntity r) => r.id).toList(), <String>['good', 'alsoGood']);
  });

  test('时间戳解析不了的那条会被丢掉（而不是变成 1970 年）', () {
    const source = '''
{"v":1,"rows":[
  {"id":"bad","title":null,"content":"c","tags":[],
   "recordedAt":"不是时间","createdAt":"2026-09-15T10:30:00.000",
   "updatedAt":"2026-09-15T10:30:00.000","deleted":false,"deletedAt":null}
]}
''';
    expect(RecordSnapshot.decode(source), isEmpty);
  });
}
