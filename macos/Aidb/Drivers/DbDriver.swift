import Foundation

enum DriverError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

/// 统一数据库驱动协议（对齐 Tauri 版 DbDriver trait）。
/// database 参数：MySQL 为库名（可空=用连接默认库）；SQLite 忽略。
protocol DbDriver: AnyObject {
    var kind: DatabaseKind { get }
    /// 测试连接，返回版本信息
    func test() async throws -> String
    /// 库列表（SQLite 固定 ["main"]）
    func listDatabases() async throws -> [String]
    func listTables(database: String?) async throws -> [TableInfo]
    func listColumns(database: String?, table: String) async throws -> [ColumnInfo]
    /// 网格分页：page 从 0 起；orderCol/whereSql 可选
    func queryPage(database: String?, table: String, page: Int, pageSize: Int,
                   orderCol: String?, orderAsc: Bool, whereSql: String?) async throws -> PageResult
    /// 执行单条语句（拆分由上层负责）
    func runStatement(database: String?, sql: String) async throws -> QueryResult
    func tableDDL(database: String?, table: String) async throws -> String
    /// 网格回写，返回影响行数
    func applyChanges(database: String?, table: String, changes: TableChanges) async throws -> Int
}

/// 网格回写 SQL 生成（纯函数，供驱动与单测复用）
enum ChangeSQL {
    static func update(kind: DatabaseKind, schema: String?, table: String, _ c: RowChange) -> (String, [GridValue]) {
        let t = SqlSafety.quoteQualified(kind: kind, schema: schema, table: table)
        let set = c.set.map { SqlSafety.quoteIdent(kind: kind, $0.0) + "=?" }.joined(separator: ",")
        let where_ = c.pk.map { SqlSafety.quoteIdent(kind: kind, $0.0) + "=?" }.joined(separator: " AND ")
        let vals = c.set.map(\.1) + c.pk.map(\.1)
        return ("UPDATE \(t) SET \(set) WHERE \(where_)", vals)
    }

    static func insert(kind: DatabaseKind, schema: String?, table: String, _ cols: [(String, GridValue)]) -> (String, [GridValue]) {
        let t = SqlSafety.quoteQualified(kind: kind, schema: schema, table: table)
        let names = cols.map { SqlSafety.quoteIdent(kind: kind, $0.0) }.joined(separator: ",")
        let marks = cols.map { _ in "?" }.joined(separator: ",")
        return ("INSERT INTO \(t) (\(names)) VALUES (\(marks))", cols.map(\.1))
    }

    static func delete(kind: DatabaseKind, schema: String?, table: String, _ pk: [(String, GridValue)]) -> (String, [GridValue]) {
        let t = SqlSafety.quoteQualified(kind: kind, schema: schema, table: table)
        let where_ = pk.map { SqlSafety.quoteIdent(kind: kind, $0.0) + "=?" }.joined(separator: " AND ")
        return ("DELETE FROM \(t) WHERE \(where_)", pk.map(\.1))
    }
}
