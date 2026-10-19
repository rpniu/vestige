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

    test('库文件落在指定目录，能正常写入并读回', () async {
      final file = File('${tmp.path}/$databaseFileName');
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
      final db = VestigeDatabase(NativeDatabase(File('${nested.path}/$databaseFileName')));
      await RecordRepository(db.recordDao).addRecord(content: '1');
      expect(File('${nested.path}/$databaseFileName').existsSync(), isTrue);
      await db.close();
    });

    test('同一份库文件被重新打开时数据还在（模拟换系统后再开）', () async {
      final file = File('${tmp.path}/$databaseFileName');

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

  group('resolveDatabaseFile · 收进 vestige 子目录', () {
    late Directory docs;

    setUp(() => docs = Directory.systemTemp.createTempSync('vestige_docs_'));

    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    Future<File> resolve({Map<String, String>? env}) => resolveDatabaseFile(
          defaultDir: () async => docs,
          env: env,
        );

    test('默认位置是 <文档>/vestige/vestige.sqlite，不再散在文档目录根下', () async {
      final file = await resolve(env: const <String, String>{});
      expect(file.path, endsWith('/$dataSubDirName/$databaseFileName'));
      expect(Directory('${docs.path}/$dataSubDirName').existsSync(), isTrue);
      expect(file.existsSync(), isFalse, reason: '解析路径不该顺手把库建出来');
    });

    test('旧位置有库、新位置没有 → 自动搬进子目录（升级不能看到空数据）', () async {
      final legacy = File('${docs.path}/$databaseFileName');
      legacy.writeAsStringSync('这是老用户的库');

      final file = await resolve(env: const <String, String>{});

      expect(file.existsSync(), isTrue, reason: '库应该已经被搬到新位置');
      expect(file.readAsStringSync(), '这是老用户的库', reason: '内容必须原样保留');
      expect(legacy.existsSync(), isFalse, reason: '同一分区内应该是移动，不是复制');
    });

    test('新旧位置都有库 → 不动新的，也不覆盖（避免把当前数据冲掉）', () async {
      final legacy = File('${docs.path}/$databaseFileName')..writeAsStringSync('旧的');
      final target = Directory('${docs.path}/$dataSubDirName')..createSync();
      File('${target.path}/$databaseFileName').writeAsStringSync('当前在用的');

      final file = await resolve(env: const <String, String>{});

      expect(file.readAsStringSync(), '当前在用的');
      expect(legacy.existsSync(), isTrue, reason: '两份都在时保持原样，不做破坏性动作');
    });

    test('没有旧文件时不报错，也不会造出空文件', () async {
      final file = await resolve(env: const <String, String>{});
      expect(file.existsSync(), isFalse);
    });

    test('设置了环境变量 → 用指定目录，且不碰默认目录', () async {
      final legacy = File('${docs.path}/$databaseFileName')..writeAsStringSync('不该被搬走');
      final custom = Directory('${docs.path}/shared-data');

      final file = await resolve(
        env: <String, String>{dataDirEnvKey: custom.path},
      );

      expect(file.path, '${custom.path}/$databaseFileName');
      expect(custom.existsSync(), isTrue, reason: '指定目录不存在时应被创建');
      expect(legacy.existsSync(), isTrue, reason: '用户已指定位置，默认目录不该被动');
      expect(Directory('${docs.path}/$dataSubDirName').existsSync(), isFalse);
    });

    test('环境变量为空白 → 退回默认子目录位置，不是当前工作目录', () async {
      final file = await resolve(env: const <String, String>{dataDirEnvKey: '   '});
      expect(file.path, '${docs.path}/$dataSubDirName/$databaseFileName');
    });
  });
}
