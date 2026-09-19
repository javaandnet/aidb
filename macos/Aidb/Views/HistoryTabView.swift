import SwiftUI
import AppKit

/// 查询历史标签：列表 + 详情 + 复用/复制/清空（持久化于配置库 sql_history 表）
struct HistoryTabView: View {
    @EnvironmentObject var app: AppModel
    @State private var entries: [HistoryEntry] = []
    @State private var selectedID: Int64?

    private var selected: HistoryEntry? {
        entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("最近 \(entries.count) 条执行记录").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { reload() }
                Button("清空历史", role: .destructive) {
                    if alertConfirm("确定清空全部查询历史？", informative: "此操作不可撤销。") {
                        ConfigStore.shared.clearHistory()
                        reload()
                    }
                }
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HSplitView {
                list.frame(minWidth: 320)
                detail.frame(minWidth: 260)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { reload() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { e in
                    row(e)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ e: HistoryEntry) -> some View {
        let active = e.id == selectedID
        HStack(spacing: 8) {
            Image(systemName: e.error == nil ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(e.error == nil ? Color.green : Color.red).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.sql.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(formatTime(e.createdAt)) · \(e.durationMs ?? 0)ms"
                        + (e.rowCount.map { " · \($0) 行" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.newSqlTab(presetSQL: e.sql) }
        .onTapGesture { selectedID = e.id }
        .contextMenu {
            Button("在新查询标签中复用") { app.newSqlTab(presetSQL: e.sql) }
            Button("复制 SQL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.sql, forType: .string)
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = selected {
                HStack {
                    Text("语句").font(.callout.weight(.medium))
                    Spacer()
                    Button("复用") { app.newSqlTab(presetSQL: e.sql) }
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.sql, forType: .string)
                    }
                }
                ScrollView {
                    Text(e.sql)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let err = e.error {
                    Divider()
                    Text(err).foregroundStyle(.red)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                Spacer()
                Text("选择左侧记录查看详情\n双击记录可在新标签中复用")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        entries = ConfigStore.shared.listHistory()
        if selectedID == nil { selectedID = entries.first?.id }
    }

    private func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func alertConfirm(_ text: String, informative: String) -> Bool {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = informative
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }
}
