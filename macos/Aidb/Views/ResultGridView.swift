import SwiftUI

/// 查询结果只读网格（SQL 标签结果区复用），带 CSV/JSON 导出
struct ResultGridView: View {
    let result: QueryResult
    /// 超过该行数仅展示前 N 行（导出仍为全量）
    var displayLimit = 500

    private let rowHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            if result.columns.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("影响 \(result.affectedRows) 行 · 耗时 \(result.elapsedMs)ms")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                grid
                Divider()
                footer
            }
        }
    }

    private var shownRows: [[GridValue]] {
        Array(result.rows.prefix(displayLimit))
    }

    /// 列宽：按列名与前 200 行采样值估算
    private var widths: [CGFloat] {
        result.columns.enumerated().map { i, name in
            var maxLen = name.count
            for row in result.rows.prefix(200) where i < row.count {
                maxLen = max(maxLen, row[i].display.count)
            }
            return min(320, max(70, CGFloat(min(maxLen, 60) + 3) * 8))
        }
    }

    private var grid: some View {
        let ws = widths
        return ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("#").font(.system(.caption, design: .monospaced))
                        .frame(width: 44).foregroundStyle(.secondary)
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { i, name in
                        Text(name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .frame(width: ws[i], alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: rowHeight + 4)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ForEach(Array(shownRows.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 0) {
                        Text("\(r + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 44).foregroundStyle(.secondary)
                        ForEach(Array(row.enumerated()), id: \.offset) { i, v in
                            Text(v.isNull ? "NULL" : v.display)
                                .italic(v.isNull)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(v.isNull ? Color.secondary : Color.primary)
                                .lineLimit(1)
                                .frame(width: ws[i], alignment: .leading)
                                .padding(.horizontal, 6)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: rowHeight)
                    .background(r % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("共 \(result.rows.count) 行"
                    + (result.rows.count > displayLimit ? "（仅显示前 \(displayLimit) 行）" : "")
                    + " · 耗时 \(result.elapsedMs)ms")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu("导出") {
                Button("CSV…") { export(.csv) }
                Button("JSON…") { export(.json) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private enum Format { case csv, json }

    private func export(_ format: Format) {
        let name = "查询结果.\(format == .csv ? "csv" : "json")"
        guard let url = Exporter.savePanel(defaultName: name) else { return }
        let text = format == .csv
            ? Exporter.csvText(columns: result.columns, rows: result.rows)
            : Exporter.jsonText(columns: result.columns, rows: result.rows)
        try? Exporter.write(text, to: url)
    }
}
