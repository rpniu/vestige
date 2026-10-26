import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:vestige/data/database/connection/native.dart';

/// 首页浮动按钮列的左右位置配置。
///
/// 三颗按钮（记一笔 FAB / 速记 / 到顶到底）作为**一整列**停靠在同一侧，
/// 配置只有一个键。文件：`<数据目录>/config/home_buttons.json`（数据目录的
/// 解析规则与数据库一致：环境变量 [dataDirEnvKey] 优先，否则 `<文档>/vestige/`）。
///
/// ```json
/// { "side": "right" }
/// ```
///
/// 合法值只有 `left` / `right`；键缺失、值非法、JSON 损坏均回退默认（右侧）
/// —— 配置文件是用户手编的，坏一个键不应该让首页起不来。
/// 首次运行会把默认配置写出成文件，方便用户发现并照着改。
const String configDirName = 'config';

/// 配置文件名（[configDirName] 内）。
const String homeButtonsConfigFileName = 'home_buttons.json';

/// 按钮停靠边。
enum ButtonSide { left, right }

/// 默认停靠边（右侧）。
const ButtonSide defaultButtonSide = ButtonSide.right;

/// 把 JSON 里的一个值解析成 [ButtonSide]。
///
/// 大小写与首尾空白容忍；非法值落 [defaultButtonSide]，不抛异常。
ButtonSide parseButtonSide(Object? raw) {
  if (raw is String) {
    switch (raw.trim().toLowerCase()) {
      case 'left':
        return ButtonSide.left;
      case 'right':
        return ButtonSide.right;
    }
  }
  return defaultButtonSide;
}

/// 从配置 JSON 解析停靠边。任何不合规的输入都落默认值。
///
/// 抽成纯函数是为了单测 —— 文件读取在 [loadButtonSide] 里。
/// 兼容历史遗留键：整列配置曾拆成 `newAndQuickNote` / `jump` 两键，
/// 读取时 `side` 优先，缺了再退回旧键（旧文件里两键理论上同值；
/// 万一不同，以 `newAndQuickNote` 为准）。
ButtonSide parseButtonSideJson(Map<String, dynamic>? json) {
  final side = json?['side'];
  if (side != null) return parseButtonSide(side);
  final legacyGroup = json?['newAndQuickNote'];
  if (legacyGroup != null) return parseButtonSide(legacyGroup);
  final legacyJump = json?['jump'];
  if (legacyJump != null) return parseButtonSide(legacyJump);
  return defaultButtonSide;
}

/// 解析出配置目录：数据目录（与数据库同源，见 [resolveDatabaseFile]）下的
/// `config/` 子目录，必要时创建。
///
/// [defaultDir] 做成参数与 [resolveDatabaseFile] 同理：测试里塞临时目录，
/// 绕开 path_provider 的平台通道依赖。
Future<Directory> resolveConfigDir({
  required Future<Directory> Function() defaultDir,
  Map<String, String>? env,
}) async {
  final override = dataDirOverride(env);
  final Directory dataDir;
  if (override != null) {
    dataDir = Directory(override);
  } else {
    dataDir = Directory('${(await defaultDir()).path}/$dataSubDirName');
  }
  final configDir = Directory('${dataDir.path}/$configDirName');
  if (!await configDir.exists()) {
    await configDir.create(recursive: true);
  }
  return configDir;
}

/// 读取首页按钮停靠边。
///
/// 文件不存在时写出一份默认配置（让用户打开 config 目录就能看到可改的模板，
/// 而不是对着一个空目录猜格式）；文件存在但内容损坏时按默认值生效、
/// **不回写** —— 用户的文件里可能有半截手改内容，覆盖掉比不生效更糟。
Future<ButtonSide> loadButtonSide({
  required Future<Directory> Function() defaultDir,
  Map<String, String>? env,
}) async {
  final configDir = await resolveConfigDir(defaultDir: defaultDir, env: env);
  final file = File('${configDir.path}/$homeButtonsConfigFileName');

  if (!await file.exists()) {
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, String>{
          'side': 'right',
        }),
      );
    } on FileSystemException {
      // 写不出模板（只读盘、权限等）不致命：配置按默认值生效即可。
    }
    return defaultButtonSide;
  }

  try {
    final decoded = jsonDecode(await file.readAsString());
    return parseButtonSideJson(decoded is Map<String, dynamic> ? decoded : null);
  } on FormatException {
    return defaultButtonSide;
  }
}

/// 便捷入口：应用运行时的真实加载（走平台文档目录）。
Future<ButtonSide> loadButtonSideFromPlatform() =>
    loadButtonSide(defaultDir: getApplicationDocumentsDirectory);

/// 把 [side] 写回配置文件（覆盖式）。
///
/// 供「我的」页的 GUI 开关调用。文件不存在（极端竞态：模板还没写出用户就
/// 改了设置）会连带目录一起创建。
Future<void> saveButtonSide(
  ButtonSide side, {
  required Future<Directory> Function() defaultDir,
  Map<String, String>? env,
}) async {
  final configDir = await resolveConfigDir(defaultDir: defaultDir, env: env);
  final file = File('${configDir.path}/$homeButtonsConfigFileName');
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, String>{
      'side': side == ButtonSide.left ? 'left' : 'right',
    }),
  );
}

/// [saveButtonSide] 的便捷入口（走平台文档目录）。
Future<void> saveButtonSideToPlatform(ButtonSide side) =>
    saveButtonSide(side, defaultDir: getApplicationDocumentsDirectory);
