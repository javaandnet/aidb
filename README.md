# aidb

macOS 数据库查询客户端（TablePlus 风格），支持 **SQLite** 与 **MySQL**。

- 技术栈：Tauri 2（Rust 后端）+ Vue 3 + TypeScript + CodeMirror 6
- SQLite 使用 `rusqlite`（bundled），MySQL 使用纯 Rust 驱动 `mysql_async`，无外部依赖
- 连接密码存 macOS Keychain（service=`aidb`），连接档案/SQL 历史存本地 SQLite 配置库

## 功能

- 连接管理：新建/编辑/删除连接档案，测试连接
- 库表树：连接 → 数据库 → 表/视图，懒加载
- 数据网格：分页、排序、WHERE 筛选、单元格编辑按主键回写（⌘S）、增删行、CSV/JSON 导出、CSV 导入向导
- SQL 编辑器：多标签、schema 自动补全、⌘↵ 执行（选中语句优先）、多结果面板、查询历史
- 结构编辑：加列/改名/改类型/删列、建表（SQLite 不支持的 ALTER 给出迁移 SQL）、DDL 查看

## 开发

```bash
npm install
npm run tauri dev      # 热更新开发
npm run tauri build    # 产出 .app / .dmg（Apple Silicon）
cd src-tauri && cargo test
```

## 目录

- `src/` — Vue 3 前端（组件、pinia store、Tauri invoke 封装）
- `src-tauri/src/` — Rust 后端：`store.rs`（配置库+Keychain）、`driver/`（sqlite/mysql 驱动）、`commands.rs`（Tauri command）
