import Foundation
import SQLite3

/// SQLite 驱动：直链系统 libsqlite3，串行队列 + continuation 封装为 async。
final class SqliteDriver: DbDriver {
    let kind: DatabaseKind = .sqlite
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "aidb.sqlite.driver")
    private let path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw DriverError.message("无法打开数据库：\(msg)")
        }
        db = handle
        sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    private func perform<T>(_ block: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try block()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func lastError() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "未连接"
    }

    // MARK: 值绑定与读取

    private func bind(_ stmt: OpaquePointer?, index: Int32, value: GridValue) {
        switch value {
        case .null:
            sqlite3_bind_null(stmt, index)
        case .text(let s):
            sqlite3_bind_text(stmt, index, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case .integer(let i):
            sqlite3_bind_int64(stmt, index, i)
        case .uinteger(let u):
            sqlite3_bind_int64(stmt, index, Int64(bitPattern: u <= UInt64(Int64.max) ? u : UInt64(Int64.max)))
        case .real(let d):
            sqlite3_bind_double(stmt, index, d)
        case .blob(let data):
            data.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
    }

    private func columnValue(_ stmt: OpaquePointer?, _ i: Int32) -> GridValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_NULL: return .null
        case SQLITE_BLOB:
            let ptr = sqlite3_column_blob(stmt, i)
            let n = Int(sqlite3_column_bytes(stmt, i))
            return .blob(ptr == nil ? Data() : Data(bytes: ptr!, count: n))
        default:
            guard let p = sqlite3_column_text(stmt, i) else { return .null }
            return .text(String(cString: p))
        }
    }

    /// 同步执行单条语句并收集结果
    private func rawExec(_ sql: String, _ vals: [GridValue] = []) throws -> QueryResult {
        guard let db else { throw DriverError.message("未连接") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DriverError.message(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in vals.enumerated() { bind(stmt, index: Int32(i + 1), value: v) }

        var res = QueryResult()
        res.statement = sql
        res.isQuery = SqlSafety.isReadonlyStmt(sql)
        let t0 = Date()
        if sqlite3_column_count(stmt) > 0 {
            for i in 0..<sqlite3_column_count(stmt) {
                res.columns.append(String(cString: sqlite3_column_name(stmt, i)))
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [GridValue] = []
                for i in 0..<sqlite3_column_count(stmt) {
                    row.append(columnValue(stmt, i))
                }
                res.rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DriverError.message(lastError())
            }
        }
        res.elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        res.affectedRows = Int(sqlite3_changes(db))
        return res
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let r = try rawExec(sql)
        guard let first = r.rows.first?.first, case .integer(let i) = first else { return 0 }
        return i
    }

    // MARK: DbDriver

    func test() async throws -> String {
        try await perform {
            let r = try self.rawExec("SELECT sqlite_version()")
            return "SQLite " + (r.rows.first?.first?.display ?? "?")
        }
    }

    func listDatabases() async throws -> [String] { ["main"] }

    func listTables(database: String?) async throws -> [TableInfo] {
        try await perform {
            let r = try self.rawExec("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """)
            return r.rows.map { t in
                TableInfo(name: t[0].display, schema: "main", kind: t[1].display == "view" ? "view" : "table")
            }
        }
    }

    func listColumns(database: String?, table: String) async throws -> [ColumnInfo] {
        try await perform {
            // PRAGMA 无法参数绑定，表名经转义拼接（与 Tauri 版一致）
            let r = try self.rawExec("PRAGMA table_info(\(SqlSafety.quoteIdent(kind: .sqlite, table)))")
            return r.rows.map { row in
                ColumnInfo(
                    name: row[1].display,
                    dataType: row[2].display,
                    notNull: row[3].display == "1",
                    defaultValue: row[4].isNull ? nil : row[4].display,
                    pkPos: row[5].display == "0" || row[5].display.isEmpty ? nil : Int(row[5].display),
                    extra: nil
                )
            }
        }
    }

    func queryPage(database: String?, table: String, page: Int, pageSize: Int,
                   orderCol: String?, orderAsc: Bool, whereSql: String?) async throws -> PageResult {
        try await perform {
            let t = SqlSafety.quoteIdent(kind: .sqlite, table)
            let filter = (whereSql?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? " WHERE \(whereSql!)" : ""
            let total = try self.scalarInt("SELECT COUNT(*) FROM \(t)\(filter)")
            var sql = "SELECT * FROM \(t)\(filter)"
            if let col = orderCol, !col.isEmpty {
                sql += " ORDER BY \(SqlSafety.quoteIdent(kind: .sqlite, col)) \(orderAsc ? "ASC" : "DESC")"
            }
            sql += " LIMIT \(pageSize) OFFSET \(page * pageSize)"
            let r = try self.rawExec(sql)
            return PageResult(total: total, result: r)
        }
    }

    func runStatement(database: String?, sql: String) async throws -> QueryResult {
        try await perform { try self.rawExec(sql) }
    }

    func tableDDL(database: String?, table: String) async throws -> String {
        try await perform {
            let r = try self.rawExec("SELECT sql FROM sqlite_master WHERE name=?", [.text(table)])
            return r.rows.first?.first?.display ?? "-- 未找到对象 \(table)"
        }
    }

    func applyChanges(database: String?, table: String, changes: TableChanges) async throws -> Int {
        try await perform {
            guard !changes.isEmpty else { return 0 }
            _ = try self.rawExec("BEGIN")
            do {
                var affected = 0
                for c in changes.updates {
                    let (sql, vals) = ChangeSQL.update(kind: .sqlite, schema: nil, table: table, c)
                    affected += try self.rawExec(sql, vals).affectedRows
                }
                for cols in changes.inserts {
                    let (sql, vals) = ChangeSQL.insert(kind: .sqlite, schema: nil, table: table, cols)
                    affected += try self.rawExec(sql, vals).affectedRows
                }
                for pk in changes.deletes {
                    let (sql, vals) = ChangeSQL.delete(kind: .sqlite, schema: nil, table: table, pk)
                    affected += try self.rawExec(sql, vals).affectedRows
                }
                _ = try self.rawExec("COMMIT")
                return affected
            } catch {
                _ = try? self.rawExec("ROLLBACK")
                throw error
            }
        }
    }
}
