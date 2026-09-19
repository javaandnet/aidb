import Foundation

/// SQL 安全工具：多语句拆分、标识符转义（移植自 Tauri 版 driver/mod.rs，行为一致）
enum SqlSafety {
    /// 是否只读语句
    static func isReadonlyStmt(_ sql: String) -> Bool {
        let up = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for p in ["SELECT", "WITH", "PRAGMA", "SHOW", "DESC", "EXPLAIN"] where up.hasPrefix(p) {
            return true
        }
        return false
    }

    /// 拆分多条 SQL：处理引号（' " `）、MySQL 反斜杠转义、双写引号、[标识符]、-- 行注释、块注释
    /// 注：按 Unicode scalar 展开（非字素簇），避免 \r\n 被合成单 Character 导致行尾判断失效
    static func splitStatements(_ sql: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars: [Character] = sql.unicodeScalars.map { Character(String($0)) }
        var i = 0
        var quote: Character?
        var bracket = false

        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == "\\" && q == "'" && i + 1 < chars.count {
                    cur.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == q {
                    if i + 1 < chars.count && chars[i + 1] == q {
                        cur.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    quote = nil
                }
                i += 1
                continue
            }
            if bracket {
                cur.append(c)
                if c == "]" { bracket = false }
                i += 1
                continue
            }
            switch c {
            case "'", "\"", "`":
                quote = c
                cur.append(c)
                i += 1
            case "[":
                bracket = true
                cur.append(c)
                i += 1
            case "-" where i + 1 < chars.count && chars[i + 1] == "-":
                while i < chars.count && chars[i] != "\n" && chars[i] != "\r" {
                    cur.append(chars[i])
                    i += 1
                }
            case "/" where i + 1 < chars.count && chars[i + 1] == "*":
                cur.append(c)
                i += 1
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    cur.append(chars[i])
                    i += 1
                }
                if i < chars.count {
                    cur.append("*")
                    cur.append("/")
                    i += 2
                }
            case ";":
                flush()
                i += 1
            default:
                cur.append(c)
                i += 1
            }
        }
        flush()
        return out
    }

    /// 标识符转义：sqlite 双引号（内部 " 双写）、mysql 反引号（内部 ` 双写）
    static func quoteIdent(kind: DatabaseKind, _ name: String) -> String {
        if kind == .mysql {
            return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// schema.table 限定名
    static func quoteQualified(kind: DatabaseKind, schema: String?, table: String) -> String {
        if let s = schema, !s.isEmpty {
            return quoteIdent(kind: kind, s) + "." + quoteIdent(kind: kind, table)
        }
        return quoteIdent(kind: kind, table)
    }
}
