# Vestige

纯本地的记录 App：所有数据只存在设备上、不联网。核心体验是「秒记」——右下角一键记下今天的想法；同时把「补记」（事后补交过去的记录）做成一等公民，忘了记不要紧，补上就好。

## 特性

- **纯本地、零账号**：无网络请求、无用户系统，数据库文件可整目录备份/搬移
- **补记**：「记录属于哪天」与「何时写进库」是两个独立字段，补记自动用琥珀色标记，并进入统计口径
- **速记**：右下角一键记录，列表行高固定、惰性构建，大量记录也不卡
- **记录时长**：编辑页滚轮手填，或首页一键计时自动结算（秒级精度）；统计页按时长汇总
- **可撤销**：批量操作前先落库快照，跨会话可回退（保留最近 20 步操作历史）
- **回收站**：软删除 + 恢复
- **CSV 导入 / 导出**：完整备份，跨设备迁移
- **多平台**：Android / Windows / macOS / Linux / iOS / Web

## 技术栈

Flutter 3.47 · Dart 3.13 · Riverpod · drift (SQLite) · go_router · flex_color_scheme · fl_chart

## 项目结构

```
lib/
├── app/          # 入口、路由、主题
├── data/         # drift 数据库、DAO、迁移
├── domain/       # 纯 Dart 业务逻辑（可单测）
├── presentation/ # 页面、组件、Riverpod provider
└── main.dart
```

## 本地运行

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 生成 drift 代码（*.g.dart 不入库）
flutter run
```

## 测试

```bash
flutter test
```

## 构建

推 `v1.2.3[+N]` 形式的 tag 触发 GitHub Actions：先跑 analyze + test，通过后自动签名打 APK 并发布 Release（签名密钥走仓库 Secrets，不入库）。

## License

[MIT](LICENSE)
