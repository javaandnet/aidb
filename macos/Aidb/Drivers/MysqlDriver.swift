import Foundation
import NIOCore
import NIOPosix
import Logging
import MySQLNIO

/// MySQL 驱动：vapor mysql-nio（纯 Swift），串行队列 + 单条连接，future.wait() 桥接 async。
final class MysqlDriver: DbDriver {
    let kind: DatabaseKind = .mysql

    private let host: String
    private let port: UInt16
    private let user: String
    private let password: String
    private let database: String?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let queue = DispatchQueue(label: "aidb.mysql.driver")
    private var conn: MySQLConnection?
    private var currentDB: String?
    private let logger = Logger(label: "aidb.mysql")

    init(host: String, port: UInt16, user: String, password: String, database: String?) throws {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.currentDB = database
    }

    deinit {
        if let conn {
            _ = try? conn.close().wait()
        }
        try? group.syncShutdownGracefully()
    }

    // MARK: 连接与执行

    private func connect() throws -> MySQLConnection {
        if let conn, !conn.isClosed { return conn }
        let addr = try SocketAddress.makeAddressResolvingHost(host, port: Int(port))
        let c = try MySQLConnection.connect(
            to: addr,
            username: user,
            database: database ?? "",
            password: password,
            tlsConfiguration: TLSConfiguration.makeClientConfiguration(),
            serverHostname: host,
            logger: logger,
            on: group.next()
        ).wait()
        conn = c
        return c
    }

    private func perform<T>(_ block: @escaping (MySQLConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try block(self.connect())) }
                catch { cont.resume(throwing: Self.translate(error)) }
            }
        }
    }

    /// 切库（懒执行：与上次相同则跳过）
    private func use(_ c: MySQLConnection, _ db: String?) throws {
        guard let db, !db.isEmpty else { return }
        if currentDB == db { return }
        _ = try c.query("USE \(SqlSafety.quoteIdent(kind: .mysql, db))").wait()
        currentDB = db
    }

    private static func translate(_ error: Error) -> Error {
        if let e = error as? DriverError { return e }
        return DriverError.message(error.localizedDescription)
    }

    /// 同步执行（在 queue 上调用）并收集结果
    private func exec(_ c: MySQLConnection, _ sql: String, _ vals: [MySQLData] = []) throws -> QueryResult {
        let t0 = Date()
        var affected: UInt64 = 0
        let rows: [MySQLRow]
        if vals.isEmpty {
            rows = try c.query(sql, []) { m in affected = m.affectedRows }.wait()
        } else {
            rows = try c.query(sql, vals) { m in affected = m.affectedRows }.wait()
        }
        var res = QueryResult()
        res.statement = sql
        res.isQuery = SqlSafety.isReadonlyStmt(sql)
        if let first = rows.first {
            res.columns = first.columnDefinitions.map(\.name)
        }
        res.rows = try rows.map { row in
            try row.columnDefinitions.indices.map { i in
                let col = row.columnDefinitions[i]
                let d = MySQLData(type: col.columnType, format: row.format,
                                  buffer: row.values[i],
                                  isUnsigned: col.flags.contains(.COLUMN_UNSIGNED))
                return Self.toGridValue(d)
            }
        }
        res.affectedRows = Int(affected)
        res.elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        return res
    }

    private func scalarInt(_ c: MySQLConnection, _ sql: String) throws -> Int64 {
        let r = try exec(c, sql)
        guard let first = r.rows.first?.first, case .integer(let i) = first else { return 0 }
        return i
    }

    // MARK: 值映射

    static func toGridValue(_ d: MySQLData) -> GridValue {
        guard let buffer = d.buffer, d.type != .null else { return .null }
        switch d.type {
        case .tiny, .short, .long, .int24, .longlong, .year, .bit:
            if d.isUnsigned, let u = d.uint64 { return .uinteger(u) }
            if let i = d.int64 { return .integer(i) }
        case .float, .double:
            if let f = d.double { return .real(f) }
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .geometry:
            // 二进制类型一律按 blob 呈现（含二进制安全字符串）
            if d.format == .text, let s = d.string, s.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) {
                return .text(s)
            }
            var b = buffer
            return .blob(Data(b.readBytes(length: b.readableBytes) ?? []))
        default:
            break
        }
        if let s = d.string { return .text(s) }
        if let t = d.time { return .text(String(describing: t)) }
        if let dt = d.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return .text(f.string(from: dt))
        }
        return .text(String(describing: d))
    }

    static func toMySQLData(_ v: GridValue) -> MySQLData {
        switch v {
        case .null: return .null
        case .text(let s): return MySQLData(string: s)
        case .integer(let i): return MySQLData(int: Int(i))
        case .uinteger(let u): return MySQLData(int: Int(bitPattern: UInt(truncatingIfNeeded: u)))
        case .real(let d): return MySQLData(double: d)
        case .blob(let data):
            var buf = ByteBufferAllocator().buffer(capacity: data.count)
            buf.writeBytes(data)
            return MySQLData(type: .blob, format: .binary, buffer: buf)
        }
    }

    // MARK: DbDriver

    func test() async throws -> String {
        try await perform { c in
            let r = try self.exec(c, "SELECT VERSION()")
            return "MySQL " + (r.rows.first?.first?.display ?? "?")
        }
    }

    func listDatabases() async throws -> [String] {
        try await perform { c in
            try self.exec(c, "SHOW DATABASES")
                .rows.compactMap { $0.first?.textValue }
        }
    }

    func listTables(database: String?) async throws -> [TableInfo] {
        try await perform { c in
            try self.use(c, database)
            let r = try self.exec(c, """
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY TABLE_NAME
            """)
            return r.rows.map { t in
                TableInfo(name: t[0].display,
                          schema: database ?? self.currentDB ?? "",
                          kind: t[1].display == "VIEW" ? "view" : "table")
            }
        }
    }

    func listColumns(database: String?, table: String) async throws -> [ColumnInfo] {
        try await perform { c in
            try self.use(c, database)
            let r = try self.exec(c, """
            SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
            """, [.init(string: table)])
            var pkCounter = 0
            return r.rows.map { row in
                let isPk = row[4].textValue == "PRI"
                if isPk { pkCounter += 1 }
                return ColumnInfo(
                    name: row[0].display,
                    dataType: row[1].display,
                    notNull: row[2].textValue == "NO",
                    defaultValue: row[3].isNull ? nil : row[3].display,
                    pkPos: isPk ? pkCounter : nil,
                    extra: row[5].isNull ? nil : row[5].display
                )
            }
        }
    }

    func queryPage(database: String?, table: String, page: Int, pageSize: Int,
                   orderCol: String?, orderAsc: Bool, whereSql: String?) async throws -> PageResult {
        try await perform { c in
            try self.use(c, database)
            let t = SqlSafety.quoteIdent(kind: .mysql, table)
            let filter = (whereSql?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? " WHERE \(whereSql!)" : ""
            let total = try self.scalarInt(c, "SELECT COUNT(*) FROM \(t)\(filter)")
            var sql = "SELECT * FROM \(t)\(filter)"
            if let col = orderCol, !col.isEmpty {
                sql += " ORDER BY \(SqlSafety.quoteIdent(kind: .mysql, col)) \(orderAsc ? "ASC" : "DESC")"
            }
            sql += " LIMIT \(pageSize) OFFSET \(page * pageSize)"
            let r = try self.exec(c, sql)
            return PageResult(total: total, result: r)
        }
    }

    func runStatement(database: String?, sql: String) async throws -> QueryResult {
        try await perform { c in
            try self.use(c, database)
            return try self.exec(c, sql)
        }
    }

    func tableDDL(database: String?, table: String) async throws -> String {
        try await perform { c in
            try self.use(c, database)
            let r = try self.exec(c, "SHOW CREATE TABLE \(SqlSafety.quoteQualified(kind: .mysql, schema: database, table: table))")
            return r.rows.first?.last?.display ?? "-- 未找到对象 \(table)"
        }
    }

    func applyChanges(database: String?, table: String, changes: TableChanges) async throws -> Int {
        try await perform { c in
            guard !changes.isEmpty else { return 0 }
            try self.use(c, database)
            let schema = database ?? self.currentDB
            _ = try self.exec(c, "BEGIN")
            do {
                var affected = 0
                for ch in changes.updates {
                    let (sql, vals) = ChangeSQL.update(kind: .mysql, schema: schema, table: table, ch)
                    affected += try self.exec(c, sql, vals.map(Self.toMySQLData)).affectedRows
                }
                for cols in changes.inserts {
                    let (sql, vals) = ChangeSQL.insert(kind: .mysql, schema: schema, table: table, cols)
                    affected += try self.exec(c, sql, vals.map(Self.toMySQLData)).affectedRows
                }
                for pk in changes.deletes {
                    let (sql, vals) = ChangeSQL.delete(kind: .mysql, schema: schema, table: table, pk)
                    affected += try self.exec(c, sql, vals.map(Self.toMySQLData)).affectedRows
                }
                _ = try self.exec(c, "COMMIT")
                return affected
            } catch {
                _ = try? self.exec(c, "ROLLBACK")
                throw error
            }
        }
    }
}
