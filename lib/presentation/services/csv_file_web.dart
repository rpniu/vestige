/// Web 端没有文件系统：导出走浏览器下载 / 分享面板，所以这里恒失败，
/// 页面会自动退回「分享 CSV 文本」的路径。
Future<String?> writeTempCsv(String csv, String fileName) async => null;

Future<bool> writeCsvToPath(String path, String csv) async => false;
