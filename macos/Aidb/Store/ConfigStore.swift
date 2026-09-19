import Foundation
import SQLite3

/// 应用配置库（系统 SQLite）：~/Library/Application Support/aidb-mac/config.db
/// 表含 created_at/updated_at/created_by/updated_by 审计字段（沿用工程准则）。
/// 密码不入库，由 KeychainStore 承载。
final class ConfigStore {
    static let shared = ConfigStore()

    private var db: OpaquePointer?

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aidb-mac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.db").path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            NSLog("aidb: failed to open config db at \(path)")
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        bootstrap()
    }

    deinit { sqlite3_close(db) }

    private func bootstrap() {
        exec("""
        CREATE TABLE IF NOT EXISTS connection (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            path TEXT,
            host TEXT,
            port INTEGER,
            user TEXT,
            database TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            created_by TEXT NOT NULL,
            updated_by TEXT NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS sql_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sql TEXT NOT NULL,
            duration_ms INTEGER,
            row_count INTEGER,
            error TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            created_by TEXT NOT NULL,
            updated_by TEXT NOT NULL
        )
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { NSLog("aidb config exec failed: \(String(cString: err))") }
            sqlite3_free(err)
            return false
        }
        return true
    }

    // MARK: - 连接档案

    func listConnections() -> [ConnectionProfile] {
        guard let db else { return [] }
        var out: [ConnectionProfile] = []
        let sql = "SELECT id,name,kind,path,host,port,user,database,created_at,updated_at,created_by,updated_by FROM connection ORDER BY created_at"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var p = ConnectionProfile(
                id: text(0) ?? UUID().uuidString,
                name: text(1) ?? "",
                kind: DatabaseKind(rawValue: text(2) ?? "sqlite") ?? .sqlite,
                path: text(3),
                host: text(4),
                port: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5)),
                user: text(6),
                database: text(7)
            )
            p.createdAt = sqlite3_column_int64(stmt, 8)
            p.updatedAt = sqlite3_column_int64(stmt, 9)
            p.createdBy = text(10) ?? "local"
            p.updatedBy = text(11) ?? "local"
            out.append(p)
        }
        return out
    }

    func saveConnection(_ profile: ConnectionProfile, password: String?) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO connection (id,name,kind,path,host,port,user,database,created_at,updated_at,created_by,updated_by)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, kind=excluded.kind, path=excluded.path, host=excluded.host,
            port=excluded.port, user=excluded.user, database=excluded.database,
            updated_at=excluded.updated_at, updated_by=excluded.updated_by
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        bindText(stmt, 1, profile.id)
        bindText(stmt, 2, profile.name)
        bindText(stmt, 3, profile.kind.rawValue)
        bindText(stmt, 4, profile.path)
        bindText(stmt, 5, profile.host)
        if let port = profile.port { sqlite3_bind_int64(stmt, 6, Int64(port)) } else { sqlite3_bind_null(stmt, 6) }
        bindText(stmt, 7, profile.user)
        bindText(stmt, 8, profile.database)
        sqlite3_bind_int64(stmt, 9, profile.createdAt == 0 ? now : profile.createdAt)
        sqlite3_bind_int64(stmt, 10, now)
        bindText(stmt, 11, profile.createdBy)
        bindText(stmt, 12, "local")
        sqlite3_step(stmt)
        // 密码：非 nil 才写入（空串视为删除）；nil 表示不改动
        if let password {
            if password.isEmpty {
                KeychainStore.delete(account: profile.keychainAccount)
            } else {
                KeychainStore.set(account: profile.keychainAccount, value: password)
            }
        }
    }

    func deleteConnection(id: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM connection WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        KeychainStore.delete(account: "conn:\(id)")
    }

    func password(for profile: ConnectionProfile) -> String? {
        KeychainStore.get(account: profile.keychainAccount)
    }

    // MARK: - SQL 历史

    func addHistory(sql: String, durationMs: Int?, rowCount: Int?, error: String?) {
        guard let db else { return }
        var stmt: OpaquePointer?
        let s = """
        INSERT INTO sql_history (sql,duration_ms,row_count,error,created_at,updated_at,created_by,updated_by)
        VALUES (?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, s, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        bindText(stmt, 1, sql)
        if let d = durationMs { sqlite3_bind_int64(stmt, 2, Int64(d)) } else { sqlite3_bind_null(stmt, 2) }
        if let r = rowCount { sqlite3_bind_int64(stmt, 3, Int64(r)) } else { sqlite3_bind_null(stmt, 3) }
        bindText(stmt, 4, error)
        sqlite3_bind_int64(stmt, 5, now)
        sqlite3_bind_int64(stmt, 6, now)
        bindText(stmt, 7, "local")
        bindText(stmt, 8, "local")
        sqlite3_step(stmt)
        // 保留最近 1000 条
        exec("DELETE FROM sql_history WHERE id NOT IN (SELECT id FROM sql_history ORDER BY id DESC LIMIT 1000)")
    }

    func listHistory(limit: Int = 300) -> [HistoryEntry] {
        guard let db else { return [] }
        var out: [HistoryEntry] = []
        var stmt: OpaquePointer?
        let s = "SELECT id,sql,duration_ms,row_count,error,created_at FROM sql_history ORDER BY id DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, s, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                sql: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                createdAt: sqlite3_column_int64(stmt, 5),
                durationMs: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2),
                rowCount: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
                error: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return out
    }

    func clearHistory() {
        exec("DELETE FROM sql_history")
    }

    // MARK: - 绑定工具

    fileprivate func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(stmt, idx); return }
        sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
