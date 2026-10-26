// 首页按钮列停靠边配置（<数据目录>/config/home_buttons.json）的测试。
//
// 钉住四类行为：
// 1. 纯解析函数对脏输入的容错（键缺失 / 值非法 / 大小写 / 旧版两键文件）；
// 2. 文件不存在时写出默认模板（让用户能发现并照着改）；
// 3. 文件存在但损坏时按默认值生效、且不回写用户文件；
// 4. GUI 写回往返（写入 → 读回一致，覆盖式替换旧内容）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/data/config/home_layout_config.dart';
import 'package:vestige/data/database/connection/native.dart'
    show dataDirEnvKey, dataSubDirName;

void main() {
  group('parseButtonSideJson · 纯解析', () {
    test('null / 空表 / 缺键 → 默认（右侧）', () {
      expect(parseButtonSideJson(null), defaultButtonSide);
      expect(parseButtonSideJson(<String, dynamic>{}), defaultButtonSide);
    });

    test('left / right 生效，大小写与首尾空白容忍（用户手编文件）', () {
      expect(
        parseButtonSideJson(<String, dynamic>{'side': 'left'}),
        ButtonSide.left,
      );
      expect(
        parseButtonSideJson(<String, dynamic>{'side': '  RIGHT '}),
        ButtonSide.right,
      );
    });

    test('非法值 / 非字符串 → 默认，不抛异常', () {
      expect(
        parseButtonSideJson(<String, dynamic>{'side': 'top'}),
        defaultButtonSide,
      );
      expect(
        parseButtonSideJson(<String, dynamic>{'side': 42}),
        defaultButtonSide,
      );
    });

    test('旧版两键文件兼容：side 缺失时退回 newAndQuickNote / jump', () {
      expect(
        parseButtonSideJson(<String, dynamic>{'newAndQuickNote': 'left'}),
        ButtonSide.left,
      );
      expect(
        parseButtonSideJson(<String, dynamic>{'jump': 'left'}),
        ButtonSide.left,
      );
      // 旧键也在但非法 → 默认
      expect(
        parseButtonSideJson(<String, dynamic>{'newAndQuickNote': 'x'}),
        defaultButtonSide,
      );
    });

    test('side 与旧键同时存在 → side 优先', () {
      expect(
        parseButtonSideJson(<String, dynamic>{'side': 'left', 'jump': 'right'}),
        ButtonSide.left,
      );
    });
  });

  group('loadButtonSide · 文件读取', () {
    late Directory docs;

    setUp(() => docs = Directory.systemTemp.createTempSync('vestige_cfg_'));
    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    Future<ButtonSide> load({Map<String, String>? env}) =>
        loadButtonSide(defaultDir: () async => docs, env: env);

    File configFile() => File(
          '${docs.path}/$dataSubDirName/$configDirName/$homeButtonsConfigFileName',
        );

    test('文件不存在 → 默认值，且写出可编辑的模板文件', () async {
      final side = await load(env: const <String, String>{});

      expect(side, defaultButtonSide);
      expect(configFile().existsSync(), isTrue, reason: '应写出默认模板供用户修改');

      final written =
          jsonDecode(configFile().readAsStringSync()) as Map<String, dynamic>;
      expect(written['side'], 'right');
    });

    test('配置为 left → 生效', () async {
      Directory('${docs.path}/$dataSubDirName/$configDirName')
          .createSync(recursive: true);
      configFile().writeAsStringSync(jsonEncode(<String, String>{'side': 'left'}));

      expect(await load(env: const <String, String>{}), ButtonSide.left);
    });

    test('损坏的 JSON → 默认值生效，且不回写用户文件', () async {
      Directory('${docs.path}/$dataSubDirName/$configDirName')
          .createSync(recursive: true);
      configFile().writeAsStringSync('{ side: ');

      expect(await load(env: const <String, String>{}), defaultButtonSide);
      expect(configFile().readAsStringSync(), '{ side: ',
          reason: '用户文件里的半截内容不该被覆盖');
    });

    test('环境变量指定的数据目录优先，默认目录不被动', () async {
      final custom = Directory('${docs.path}/shared-data');

      await load(env: <String, String>{dataDirEnvKey: custom.path});

      expect(
        File('${custom.path}/$configDirName/$homeButtonsConfigFileName')
            .existsSync(),
        isTrue,
      );
      expect(Directory('${docs.path}/$dataSubDirName').existsSync(), isFalse);
    });

    test('JSON 顶层不是对象（比如数组）→ 默认值', () async {
      Directory('${docs.path}/$dataSubDirName/$configDirName')
          .createSync(recursive: true);
      configFile().writeAsStringSync('["left"]');

      expect(await load(env: const <String, String>{}), defaultButtonSide);
    });
  });

  group('saveButtonSide · GUI 写回', () {
    late Directory docs;

    setUp(() => docs = Directory.systemTemp.createTempSync('vestige_cfg_'));
    tearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });

    Future<ButtonSide> load() => loadButtonSide(
          defaultDir: () async => docs,
          env: const <String, String>{},
        );

    Future<void> save(ButtonSide side) => saveButtonSide(
          side,
          defaultDir: () async => docs,
          env: const <String, String>{},
        );

    File configFile() => File(
          '${docs.path}/$dataSubDirName/$configDirName/$homeButtonsConfigFileName',
        );

    test('写入后能原样读回，目录不存在时连带创建', () async {
      await save(ButtonSide.left);

      expect(configFile().existsSync(), isTrue, reason: 'config 目录应被连带创建');
      expect(await load(), ButtonSide.left, reason: '写进去的停靠边应能原样读回');
    });

    test('覆盖式写回：旧两键文件被新的单键内容整体替换', () async {
      Directory('${docs.path}/$dataSubDirName/$configDirName')
          .createSync(recursive: true);
      configFile().writeAsStringSync(
        jsonEncode(<String, String>{'newAndQuickNote': 'left', 'jump': 'left'}),
      );

      await save(ButtonSide.right);

      expect(await load(), ButtonSide.right);
      final written =
          jsonDecode(configFile().readAsStringSync()) as Map<String, dynamic>;
      expect(written.keys, <String>['side'], reason: '写回应是干净的单键格式');
    });
  });
}
