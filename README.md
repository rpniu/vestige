# Vestige

纯本地的记录 App：所有数据只存在设备上、不联网。核心体验是「秒记」——右下角一键记下今天的想法；同时把「补记」（事后补交过去的记录）做成一等公民，忘了记不要紧，补上就好。

## 特性

- **纯本地、零账号**：无网络请求、无用户系统，数据库文件可整目录备份/搬移
- **补记**：「记录属于哪天」与「何时写进库」是两个独立字段，补记自动用琥珀色标记，并进入统计口径
- **速记**：长按右下角「记一笔」直接记一条（不进编辑页），列表行高固定、惰性构建，大量记录也不卡
- **记录时长**：编辑页滚轮手填，或首页一键计时自动结算（秒级精度）；统计页按时长汇总
- **可撤销**：批量操作前先落库快照，跨会话可回退（保留最近 20 步操作历史）
- **回收站**：软删除 + 恢复
- **记录本**：可新建多份记录本（工作 / 读书 / ……），互相看不到；切换后首页、统计、回收站一起换源
- **CSV 导入 / 导出**：完整备份，跨设备迁移
- **多平台**：Android / Windows / macOS / Linux / iOS

> **不支持 Web（2026-10-27 移除）**：数据库用的是 drift，web 端要跑起来需要 `drift/wasm`
> （`drift/web` 已被上游弃用），同时目录/文件能力（`dart:io` + `path_provider`）在 web 上
> 得另写一套实现。与其留一条编译不过的路径，不如明确不支持 —— 只保留原生五端。

> **数据文件位置**：`<数据目录>/databases/vestige.sqlite`（默认数据目录是
> `<文档目录>/vestige/`，可用环境变量 `VESTIGE_DATA_DIR` 整体改到别处）。
>
> **一个库装下所有记录本**，靠两张表和一条外键区分：
> ```
> record_books(id, name, created_at)
>        ↑ book_id  ON DELETE CASCADE
> records(…)            undo_entries(…)
> ```
> 默认记录本的 id 是字面量 `default`：v7 迁移给所有既有记录回填的就是它，
> 所以升级后看到的就是原来那批数据，一行都不用搬。删掉一本记录本时，
> 它的记录与撤销历史由外键级联清掉。
>
> 文件搬家（只搬文件，不动数据）：历史上库待过 `<文档目录>/vestige.sqlite` 与
> `<数据目录>/vestige.sqlite` 两个位置，打开时会**连同 `-wal` / `-shm`** 收进
> `databases/`；目标已存在则绝不覆盖。

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
