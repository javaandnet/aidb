import Foundation

/// 网格/结果集的统一值类型（对应 Tauri 版 serde_json::Value 的处理策略）。
/// 原生端无 JS 精度问题，整数直接保留 Int64/UInt64。
enum GridValue: Equatable, Hashable {
    case null
    case text(String)
    case integer(Int64)
    case uinteger(UInt64)
    case real(Double)
    case blob(Data)

    /// 网格展示文本
    var display: String {
        switch self {
        case .null: return ""
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .uinteger(let u): return String(u)
        case .real(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .blob(let d): return "<blob \(d.count) bytes>"
        }
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    var textValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .uinteger(let u): return String(u)
        case .real(let d): return String(d)
        default: return nil
        }
    }

    /// 内联编辑器初始文本（blob/null 不给编辑文本）
    var editString: String? {
        switch self {
        case .null: return nil
        case .blob: return nil
        default: return display
        }
    }

    /// 导出用字符串（CSV/JSON 的可读表示；blob 用 base64）
    var exportString: String {
        switch self {
        case .null: return ""
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .uinteger(let u): return String(u)
        case .real(let d): return String(d)
        case .blob(let d): return d.base64EncodedString()
        }
    }
}

/// GridValue 的 JSON 表示（SQL 历史、导入导出等复用）
extension GridValue: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .t)
        switch tag {
        case "null": self = .null
        case "text": self = .text(try c.decode(String.self, forKey: .v))
        case "int": self = .integer(try c.decode(Int64.self, forKey: .v))
        case "uint": self = .uinteger(try c.decode(UInt64.self, forKey: .v))
        case "real": self = .real(try c.decode(Double.self, forKey: .v))
        case "blob": self = .blob(Data(base64Encoded: try c.decode(String.self, forKey: .v)) ?? Data())
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown tag \(tag)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try c.encode("null", forKey: .t)
        case .text(let s): try c.encode("text", forKey: .t); try c.encode(s, forKey: .v)
        case .integer(let i): try c.encode("int", forKey: .t); try c.encode(i, forKey: .v)
        case .uinteger(let u): try c.encode("uint", forKey: .t); try c.encode(u, forKey: .v)
        case .real(let d): try c.encode("real", forKey: .t); try c.encode(d, forKey: .v)
        case .blob(let b): try c.encode("blob", forKey: .t); try c.encode(b.base64EncodedString(), forKey: .v)
        }
    }
}

/// 统一查询结果（列名 + 行 + 影响行数 + 耗时），对齐 Tauri 版 QueryResult。
struct QueryResult: Identifiable {
    let id = UUID()
    var columns: [String] = []
    var rows: [[GridValue]] = []
    var affectedRows: Int = 0
    var elapsedMs: Int = 0
    /// 是否只读查询（SELECT/PRAGMA/SHOW/DESC/EXPLAIN/WITH）
    var isQuery: Bool = false
    var statement: String = ""
}

/// 数据网格分页结果
struct PageResult {
    var total: Int64
    var result: QueryResult
}

struct TableInfo: Identifiable, Hashable {
    var name: String
    var schema: String    // MySQL 为库名；SQLite 固定 "main"
    var kind: String      // "table" | "view"
    var id: String { schema + "." + name }
}

struct ColumnInfo: Identifiable, Hashable {
    var name: String
    var dataType: String
    var notNull: Bool
    var defaultValue: String?
    var pkPos: Int?       // 主键顺序（1 起），nil 非主键
    var extra: String?    // MySQL: auto_increment 等
    var id: String { name }
}

/// 行变更（网格回写）：pk = [(列名, 值)]，set = [(列名, 值)]
struct RowChange {
    var pk: [(String, GridValue)]
    var set: [(String, GridValue)]
}

struct TableChanges {
    var updates: [RowChange] = []
    var inserts: [[(String, GridValue)]] = []
    var deletes: [[(String, GridValue)]] = []
    var isEmpty: Bool { updates.isEmpty && inserts.isEmpty && deletes.isEmpty }
}
