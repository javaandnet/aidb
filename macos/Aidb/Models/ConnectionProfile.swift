import Foundation

/// 数据库类型
enum DatabaseKind: String, Codable {
    case sqlite
    case mysql
}

/// 连接档案（密码不入库，存 Keychain，account = "conn:\(id)"）。
struct ConnectionProfile: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var kind: DatabaseKind
    // SQLite
    var path: String?
    // MySQL
    var host: String?
    var port: Int?
    var user: String?
    var database: String?

    // 审计字段（沿用工程准则：毫秒时间戳，created_by 固定 "local"）
    var createdAt: Int64
    var updatedAt: Int64
    var createdBy: String
    var updatedBy: String

    init(id: String = UUID().uuidString,
         name: String,
         kind: DatabaseKind,
         path: String? = nil,
         host: String? = nil,
         port: Int? = nil,
         user: String? = nil,
         database: String? = nil) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.createdAt = now
        self.updatedAt = now
        self.createdBy = "local"
        self.updatedBy = "local"
    }

    /// 列表展示的目标：文件路径 或 user@host:port/database
    var target: String {
        switch kind {
        case .sqlite:
            return path ?? ""
        case .mysql:
            let u = user.map { $0 + "@" } ?? ""
            let d = database.map { "/" + $0 } ?? ""
            return "\(u)\(host ?? "127.0.0.1"):\(port ?? 3306)\(d)"
        }
    }

    var keychainAccount: String { "conn:\(id)" }
}

/// SQL 执行历史条目
struct HistoryEntry: Identifiable, Codable {
    var id: Int64
    var sql: String
    var createdAt: Int64
    var durationMs: Int64?
    var rowCount: Int64?
    var error: String?
}
