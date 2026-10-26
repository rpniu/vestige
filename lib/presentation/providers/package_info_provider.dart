import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 应用自身的版本信息（versionName / versionCode / 包名）。
///
/// 数据来自系统安装清单（AndroidManifest / Info.plist），也就是打包时
/// `--build-name` 写进去的值 —— CI 发版流水线用 tag 解析后传入，
/// 所以「关于」页显示的永远是**当前安装包的真实版本**，不再手写。
///
/// FutureProvider：读一次缓存住，页面刷新不重复走插件通道。
final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);
