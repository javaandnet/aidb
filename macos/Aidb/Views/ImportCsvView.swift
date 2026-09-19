import SwiftUI
import AppKit

/// CSV 导入向导：选文件 → 列映射 → 参数化批量 INSERT（走 applyChanges 事务）
struct ImportCsvView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let database: String?
    let table: String

    @State private var fileURL: URL?
    @State private var parsed: [[String]] = []
    @State private var tableColumns: [ColumnInfo] = []
    /// csv 列序号 → 目标列名（nil = 不导入该列）
    @State private var mapping: [Int: String] = [:]
    @State private var skipHeader = true
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    private var csvHeader: [String] { parsed.first ?? [] }
    private var dataRows: [[String]] {
        skipHeader && parsed.count > 1 ? Array(parsed.dropFirst()) : parsed
    }
    private var mappedCount: Int { mapping.count { _, v in tableColumns.contains { $0.name == v } } }
    private var canImport: Bool { fileURL != nil && !dataRows.isEmpty && mappedCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入 CSV → \(table)").font(.headline)

            HStack {
                Button("选择 CSV 文件…") { pickFile() }
                if let fileURL {
                    Text(fileURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("首行为表头", isOn: $skipHeader).toggleStyle(.checkbox)
                    .disabled(parsed.isEmpty)
            }

            if parsed.isEmpty {
                Spacer()
                Text("尚未选择文件").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                HSplitView {
                    mappingPane.frame(minWidth: 340)
                    previewPane.frame(minWidth: 300)
                }
            }

            if let message {
                Text(message).font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button(busy ? "导入中…" : "导入 \(dataRows.count) 行") { Task { await doImport() } }
                    .disabled(!canImport || busy)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 720, height: 480)
        .task { await loadColumns() }
    }

    // MARK: 子面板

    private var mappingPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("列映射（CSV 列 → 表列）").font(.callout.weight(.medium))
                ForEach(Array(csvHeader.enumerated()), id: \.offset) { i, name in
                    HStack {
                        Text("#\(i + 1) \(name)").lineLimit(1).frame(width: 170, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        Picker("目标列", selection: Binding(
                            get: { mapping[i] },
                            set: { if let v = $0 { mapping[i] = v } else { mapping[i] = nil } }
                        )) {
                            Text("（不导入）").tag(String?.none)
                            ForEach(tableColumns) { c in
                                Text(c.name).tag(String?.some(c.name))
                            }
                        }
                        .labelsHidden().frame(width: 180)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("数据预览（前 20 行）").font(.callout.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(Array(dataRows.prefix(20)), id: \.self) { row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                                Text(v).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .border(Color.gray.opacity(0.3))
        }
        .padding(10)
    }

    // MARK: 动作

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        fileURL = url
        parsed = CSV.parse(text)
        // 默认同名自动映射
        mapping = [:]
        for (i, h) in csvHeader.enumerated() {
            if tableColumns.contains(where: { $0.name == h }) { mapping[i] = h }
        }
        message = "已解析 \(max(0, parsed.count - (skipHeader ? 1 : 0))) 行 × \(csvHeader.count) 列"
        isError = false
    }

    private func loadColumns() async {
        guard let conn = app.connected else { return }
        tableColumns = (try? await conn.driver.listColumns(database: database, table: table)) ?? []
    }

    /// CSV 文本 → GridValue：按目标列类型推断
    private func toValue(_ text: String, col: ColumnInfo) -> GridValue {
        let t = col.dataType.uppercased()
        if t.contains("INT"), let i = Int64(text) { return .integer(i) }
        if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB"), let d = Double(text) { return .real(d) }
        return .text(text)
    }

    private func doImport() async {
        guard let conn = app.connected else { return }
        busy = true
        defer { busy = false }
        let cols = csvHeader.indices.compactMap { i -> (Int, String)? in
            guard let target = mapping[i] else { return nil }
            return (i, target)
        }
        guard !cols.isEmpty else { message = "没有映射任何列"; isError = true; return }

        var changes = TableChanges()
        for row in dataRows {
            var pairs: [(String, GridValue)] = []
            for (i, target) in cols where i < row.count {
                let info = tableColumns.first { $0.name == target }
                let v = toValue(row[i], col: info ?? ColumnInfo(name: target, dataType: "TEXT", notNull: false, defaultValue: nil, pkPos: nil, extra: nil))
                pairs.append((target, v))
            }
            if !pairs.isEmpty { changes.inserts.append(pairs) }
        }

        let started = Date()
        do {
            var affected = 0
            // 分批事务，避免超大单事务
            var batch = TableChanges()
            for ins in changes.inserts {
                batch.inserts.append(ins)
                if batch.inserts.count >= 500 {
                    affected += try await conn.driver.applyChanges(database: database, table: table, changes: batch)
                    batch.inserts.removeAll()
                }
            }
            if !batch.isEmpty {
                affected += try await conn.driver.applyChanges(database: database, table: table, changes: batch)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            message = "导入完成：\(affected) 行 · \(ms)ms"
            isError = false
            ConfigStore.shared.addHistory(sql: "CSV IMPORT INTO \(table) (\(cols.map(\.1).joined(separator: ", "))) × \(affected) rows",
                                          durationMs: ms, rowCount: affected, error: nil)
        } catch {
            message = "导入失败：\(error.localizedDescription)"
            isError = true
        }
    }
}
