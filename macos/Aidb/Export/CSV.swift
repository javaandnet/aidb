import Foundation

/// CSV 解析/序列化：RFC4180 风格带引号状态机（无第三方依赖）
enum CSV {
    /// 解析全文为 [[String]]；自动识别 \r\n、\n、\r 行尾；处理 "" 转义与引号内换行
    /// 注：按 Unicode scalar 遍历（非字素簇），否则 \r\n 会被合成一个 Character 导致行尾失效
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars: [Character] = text.unicodeScalars.map { Character(String($0)) }
        var i = 0

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(c)
                i += 1
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                i += 1
            case ",":
                endField()
                i += 1
            case "\r":
                if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                endRow()
                i += 1
            case "\n":
                endRow()
                i += 1
            default:
                field.append(c)
                i += 1
            }
        }
        // 末行（无换行结尾）：仅有内容时收录，避免尾部空行
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        // 跳过整行为空的行（连续换行）
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// 单字段是否需要加引号
    /// 注：必须按 Unicode scalar 判断——\r\n 在 Swift 中是一个 grapheme cluster，逐 Character 比较匹配不到单独的 \n/\r
    private static func needsQuote(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
    }

    /// 序列化为 CSV 文本（含表头行）
    static func serialize(header: [String], rows: [[String]]) -> String {
        var out = ""
        func line(_ fields: [String]) {
            out += fields.map { f in
                needsQuote(f) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: ",") + "\r\n"
        }
        line(header)
        for r in rows { line(r) }
        return out
    }
}
