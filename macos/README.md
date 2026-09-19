# aidb macOS 原生版（SwiftUI）

aidb 的 macOS 原生实现，与仓库根目录的 Tauri 版（`src/` + `src-tauri/`）功能对齐、同仓共存，**原生版为主**。

- 技术栈：SwiftUI + AppKit（NSTextView 自研 SQL 编辑器），macOS 14+
- 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成：源文件是 `project.yml`，`Aidb.xcodeproj/` 不入库
- SQLite 用系统 `libsqlite3`（C API 直绑）；MySQL 用 SwiftPM 包 [mysql-nio](https://github.com/vapor/mysql-nio)（纯 Swift，异步转同步桥接）

## 构建与运行

```bash
brew install xcodegen   # 仅需一次
cd macos
xcodegen generate
open Aidb.xcodeproj     # Xcode 里 ⌘R 运行
# 或命令行：
xcodebuild -project Aidb.xcodeproj -scheme Aidb -destination 'platform=macOS' build
xcodebuild -project Aidb.xcodeproj -scheme Aidb -destination 'platform=macOS' test
```

产物在 `DerivedData/Build/Products/Debug/Aidb.app`。

## 功能

- 连接管理（SQLite 文件 / MySQL 主机），连接档案与 SQL 历史存配置库
- 库表树 → 数据网格：分页/排序/WHERE、**单击单元格编辑**、**行选中高亮**、增行/**复制行**（跳过自增主键）/删除选中行、⌘S 按主键事务回写
- SQL 编辑器：语法高亮、schema 自动补全（ESC）、⌘↵ 执行选中语句优先、多语句逐条结果、查询历史双击复用
- 结构标签：加列/改名/删列/索引查看/DDL、建表表单
- CSV 导入向导（列映射+预览）、CSV/JSON 结果导出

## 本地数据位置

- 配置库：`~/Library/Application Support/aidb-mac/config.db`（含审计四字段）
- 连接密码：macOS Keychain，service = `aidb-mac`

## 目录

- `Aidb/Drivers/` — DbDriver 协议 + SqliteDriver / MysqlDriver / SqlSafety（语句拆分与标识符转义）/ ConfigStore
- `Aidb/ViewModels/` — AppModel（连接与标签生命周期）/ DataTabModel / SqlTabModel / GridValue
- `Aidb/Views/` — SwiftUI 视图 + SqlEditor（NSTextView 高亮/补全）
- `Aidb/Export/` — CSV 序列化
- `Tests/` — 单元测试（SqlSafety / CSV / GridValue / ConnectionProfile）

## 已知限制

- MySQL 驱动以编译级 + 协议一致性验证为主（开发机无常备 MySQL 实例），连库冒烟待补
- 数据网格为窗口化渲染（非位图虚拟滚动），超大结果集以每页 50–1000 行控制
