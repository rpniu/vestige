// 数据目录解析的回归测试。
//
// 背景：数据库位置原来是写死的「应用文档目录」，导致 Windows 与 Linux 各写各的
// ~/Documents，同一台机器上两个系统看到的是两份互不相干的数据。
// 现在多了一个环境变量覆盖入口（VESTIGE_DATA_DIR），这一组测试钉住两件事：
//
// 1. **没配置时行为完全不变**（否则老用户的数据库会被"搬走"）；
// 2. 库文件放在任意目录都能正常读写（跨系统共用时，路径由用户指定，
//    可能是共享分区上的任意位置）。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/database/app_database.dart';
import 'package:vestige/data/database/connection/native.dart';
import 'package:vestige/data/repositories/record_repository.dart';

void main() {
  group('dataDirOverride · 环境变量解析', () {
    test('未设置 → null（走默认文档目录，行为不变）', () {
      expect(dataDirOverride(const <String, String>{}), isNull);
    });

    test('空串 / 纯空白 → null（不能被"空值"把库丢到当前工作目录）', () {
      expect(dataDirOverride(const <String, String>{dataDirEnvKey: ''}), isNull);
      expect(dataDirOverride(const <String, String>{dataDirEnvKey: '   '}), isNull);
      expect(dataDirOverride(const <String, String>{dataDirEnvKey: '\t\n'}), isNull);
    });

    test('正常路径 → 原样返回', () {
      expect(
        dataDirOverride(const <String, String>{dataDirEnvKey: 'D:/Vestige'}),
        'D:/Vestige',
      );
      expect(
        dataDirOverride(const <String, String>{dataDirEnvKey: '/mnt/d/Vestige'}),
        '/mnt/d/Vestige',
      );
    });

    test('首尾空白被裁掉，但路径中间的空白保留', () {
      expect(
        dataDirOverride(
          const <String, String>{dataDirEnvKey: '  D:/Vestige Data  '},
        ),
        'D:/Vestige Data',
      );
    });

    test('变量名大小写敏感，写成小写不生效', () {
      expect(dataDirOverride(const <String, String>{'vestige_data_dir': 'D:/x'}), isNull);
    });
  });

  group('自定义目录下的数据库读写', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('vestige_dbtest_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // 这一组只验证「任意目录都能读写库」，文件名与真实布局无关
    const fileName = 'data.sqlite';

    test('库文件落在指定目录，能正常写入并读回', () async {
      final file = File('${tmp.path}/$fileName');
      final db = VestigeDatabase(NativeDatabase(file));
      final repo = RecordRepository(db.recordDao);

      await repo.addRecord(content: '跨系统共用测试', recordedAt: DateTime(2026, 9, 15, 10));
      final all = await repo.getAllActiveRecordsSync();

      expect(all, hasLength(1));
      expect(all.first.content, '跨系统共用测试');
      expect(file.existsSync(), isTrue, reason: '库文件应该就建在指定目录里');

      await db.close();
    });

    test('目录不存在时会先被创建（共享分区首次运行的场景）', () async {
      // 模拟「用户指定了一个还没建的目录」
      final nested = Directory('${tmp.path}/shared/vestige');
      expect(nested.existsSync(), isFalse);

      nested.createSync(recursive: true);
      final db = VestigeDatabase(NativeDatabase(File('${nested.path}/$fileName')));
      await RecordRepository(db.recordDao).addRecord(content: '1');
      expect(File('${nested.path}/$fileName').existsSync(), isTrue);
      await db.close();
    });

    test('同一份库文件被重新打开时数据还在（模拟换系统后再开）', () async {
      final file = File('${tmp.path}/$fileName');

      final first = VestigeDatabase(NativeDatabase(file));
      await RecordRepository(first.recordDao).addRecord(content: '留下的一条');
      await first.close();

      final second = VestigeDatabase(NativeDatabase(file));
      final all = await RecordRepository(second.recordDao).getAllActiveRecordsSync();
      expect(all, hasLength(1));
      expect(all.first.content, '留下的一条');
      await second.close();
    });
  });

  group('resolveDatabaseFile · 库收进 databases/', () {
    late Directory docs;

    setUp(() => docs = Directory.systemTemp.createTempSync('vestige_docs_'));

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    Future<File> resolve({Map<String, String>? env}) => resolveDatabaseFile(
          defaultDir: () async => docs,
          env: env,
        );

    /// 期望位置：`<文档>/vestige/databases/vestige.sqlite`
    String databasesDir() =>
        '${docs.path}/$dataSubDirName/$databasesSubDirName';

    test('库文件在 <文档>/vestige/databases/vestige.sqlite', () async {
      final file = await resolve(env: const <String, String>{});
      expect(file.path, '${databasesDir()}/$databaseFileName');
      expect(Directory(databasesDir()).existsSync(), isTrue);
      expect(file.existsSync(), isFalse, reason: '解析路径不该顺手把库建出来');
    });

    test('老位置（数据目录根的 vestige.sqlite）→ 搬进 databases/', () async {
      final legacy = File('${docs.path}/$dataSubDirName/$databaseFileName')
        ..createSync(recursive: true)
        ..writeAsStringSync('上一版的库');

      final file = await resolve();

      expect(file.readAsStringSync(), '上一版的库', reason: '内容必须原样保留');
      expect(legacy.existsSync(), isFalse, reason: '应该搬走，不在原处留副本');
    });

    test('更早的位置（文档目录根的 vestige.sqlite）→ 一步搬进 databases/', () async {
      final legacy = File('${docs.path}/$databaseFileName')
        ..writeAsStringSync('最早那一版的库');

      final file = await resolve();

      expect(file.path, '${databasesDir()}/$databaseFileName');
      expect(file.readAsStringSync(), '最早那一版的库');
      expect(legacy.existsSync(), isFalse);
    });

    test('两个老位置都有 → 只搬较新的那个，另一个原地不动', () async {
      final older = File('${docs.path}/$databaseFileName')..writeAsStringSync('最早');
      final newer = File('${docs.path}/$dataSubDirName/$databaseFileName')
        ..createSync(recursive: true)
        ..writeAsStringSync('较新');

      final file = await resolve();

      expect(file.readAsStringSync(), '较新');
      expect(newer.existsSync(), isFalse);
      expect(older.existsSync(), isTrue, reason: '没被选中的那份不做破坏性处理');
    });

    test('目标已存在 → 不动它，也不动老文件（绝不覆盖）', () async {
      final target = File('${databasesDir()}/$databaseFileName')
        ..createSync(recursive: true)
        ..writeAsStringSync('当前在用的');
      final legacy = File('${docs.path}/$dataSubDirName/$databaseFileName')
        ..writeAsStringSync('旧的');

      final file = await resolve();

      expect(file.path, target.path);
      expect(target.readAsStringSync(), '当前在用的');
      expect(legacy.existsSync(), isTrue, reason: '两份都在时保持原样');
    });

    test('搬家带上 -wal / -shm（只搬主文件会丢最近写入）', () async {
      final root = Directory('${docs.path}/$dataSubDirName')..createSync();
      for (final suffix in <String>['', '-wal', '-shm']) {
        File('${root.path}/$databaseFileName$suffix').writeAsStringSync('x$suffix');
      }

      final file = await resolve();

      for (final suffix in <String>['', '-wal', '-shm']) {
        expect(File('${file.path}$suffix').readAsStringSync(), 'x$suffix');
        expect(
          File('${root.path}/$databaseFileName$suffix').existsSync(),
          isFalse,
          reason: '伴生文件也要搬走，不能在原位置留半套',
        );
      }
    });

    test('搬完之后打开的是同一份数据（真实 sqlite 文件）', () async {
      final legacy = File('${docs.path}/$dataSubDirName/$databaseFileName')
        ..createSync(recursive: true);

      final oldDb = VestigeDatabase(NativeDatabase(legacy));
      await RecordRepository(oldDb.recordDao).addRecord(
        content: '升级前的记录',
        recordedAt: DateTime(2026, 9, 1, 10),
      );
      await oldDb.close();

      final file = await resolve();
      expect(file.existsSync(), isTrue, reason: '老库应该已经被搬进 databases/');

      final newDb = VestigeDatabase(NativeDatabase(file));
      final all = await RecordRepository(newDb.recordDao)
          .getAllActiveRecordsSync();
      expect(all.single.content, '升级前的记录');
      await newDb.close();
    });

    test('没有旧文件时不报错，也不会造出空库', () async {
      final file = await resolve(env: const <String, String>{});
      expect(file.existsSync(), isFalse);
    });

    test('设置了环境变量 → 用指定目录下的 databases/，且不碰默认目录', () async {
      final legacy = File('${docs.path}/$databaseFileName')
        ..writeAsStringSync('不该被搬走');
      final custom = Directory('${docs.path}/shared-data');

      final file = await resolve(
        env: <String, String>{dataDirEnvKey: custom.path},
      );

      expect(file.path, '${custom.path}/$databasesSubDirName/$databaseFileName');
      expect(custom.existsSync(), isTrue, reason: '指定目录不存在时应被创建');
      expect(legacy.existsSync(), isTrue, reason: '用户已指定位置，文档目录不该被动');
      expect(Directory('${docs.path}/$dataSubDirName').existsSync(), isFalse);
    });

    test('指定目录里上一版的 vestige.sqlite 同样会被搬进 databases/', () async {
      final custom = Directory('${docs.path}/shared-data')..createSync();
      final legacy = File('${custom.path}/$databaseFileName')
        ..writeAsStringSync('共享目录里的老库');

      final file = await resolve(env: <String, String>{dataDirEnvKey: custom.path});

      expect(
        file.path,
        '${custom.path}/$databasesSubDirName/$databaseFileName',
      );
      expect(file.readAsStringSync(), '共享目录里的老库');
      expect(legacy.existsSync(), isFalse);
    });

    test('环境变量为空白 → 退回默认数据目录，不是当前工作目录', () async {
      final file = await resolve(env: const <String, String>{dataDirEnvKey: '   '});
      expect(file.path, '${databasesDir()}/$databaseFileName');
    });
  });
}
