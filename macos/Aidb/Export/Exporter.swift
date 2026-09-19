import Foundation
import AppKit

/// 导出与保存面板工具（CSV/JSON）
enum Exporter {
    /// 弹出 NSSavePanel，返回目标 URL（取消为 nil）
    static func savePanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func csvText(columns: [String], rows: [[GridValue]]) -> String {
        CSV.serialize(header: columns, rows: rows.map { r in r.map { $0.exportString } })
    }

    static func jsonText(columns: [String], rows: [[GridValue]]) -> String {
        var out = "[\n"
        for (i, r) in rows.enumerated() {
            var pairs: [String] = []
            for (j, col) in columns.enumerated() {
                let v = j < r.count ? r[j] : .null
                pairs.append("  " + jsonString(col) + ": " + jsonValue(v))
            }
            out += "{\n" + pairs.joined(separator: ",\n") + "\n}"
            out += i == rows.count - 1 ? "\n" : ",\n"
        }
        out += "]"
        return out
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONEncoder().encode(s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }

    private static func jsonValue(_ v: GridValue) -> String {
        switch v {
        case .null: return "null"
        case .text(let s): return jsonString(s)
        case .integer(let i): return String(i)
        case .uinteger(let u): return String(u)
        case .real(let d): return String(d)
        case .blob(let b): return jsonString(b.base64EncodedString())
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url)
    }
}
