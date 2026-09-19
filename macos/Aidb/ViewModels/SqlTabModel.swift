import SwiftUI

/// SQL 标签单条语句的执行产物
struct ExecItem: Identifiable {
    let id = UUID()
    var statement: String
    var result: QueryResult?
    var error: String?
    var ms: Int = 0
    var ok: Bool { error == nil }
}

/// SQL 标签状态机：编辑器文本、多语句执行、结果集、schema 补全词（对应 Tauri 版 SqlTab.vue）
@MainActor
final class SqlTabModel: ObservableObject {
    @Published var sql: String
    @Published var items: [ExecItem] = []
    @Published var activeItemID: ExecItem.ID?
    @Published var isRunning = false
    @Published var statusText: String?
    @Published var completionWords: [String] = []

    init(spec: TabSpec) {
        sql = spec.presetSQL ?? ""
    }

    var activeItem: ExecItem? {
        if let id = activeItemID, let it = items.first(where: { $0.id == id }) { return it }
        return items.first
    }

    /// 选中优先：selected 非空只跑选中文本，否则跑全文
    func run(selected: String) async {
        guard let conn = AppModel.shared.connected else {
            statusText = "未连接数据库"
            return
        }
        let src = selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sql : selected
        let stmts = SqlSafety.splitStatements(src)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !stmts.isEmpty else {
            statusText = "没有可执行的语句"
            return
        }
        isRunning = true
        statusText = nil
        defer { isRunning = false }

        var newItems: [ExecItem] = []
        var failures = 0
        let t0 = Date()
        for stmt in stmts {
            var item = ExecItem(statement: stmt)
            let ts = Date()
            do {
                var r = try await conn.driver.runStatement(database: conn.currentDatabase, sql: stmt)
                r.elapsedMs = Int(Date().timeIntervalSince(ts) * 1000)
                item.result = r
                item.ms = r.elapsedMs
                ConfigStore.shared.addHistory(sql: stmt, durationMs: r.elapsedMs,
                                              rowCount: r.isQuery ? r.rows.count : r.affectedRows,
                                              error: nil)
            } catch {
                item.error = error.localizedDescription
                item.ms = Int(Date().timeIntervalSince(ts) * 1000)
                failures += 1
                ConfigStore.shared.addHistory(sql: stmt, durationMs: item.ms, rowCount: nil, error: item.error)
            }
            newItems.append(item)
        }
        items = newItems
        activeItemID = newItems.first?.id
        let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        statusText = "执行 \(newItems.count) 条语句 · 共 \(totalMs)ms" + (failures > 0 ? " · \(failures) 条失败" : "")
    }

    /// 补全词 = SQL 关键字 + 当前库表名/列名（表多于 80 张时略去列，避免过慢）
    func refreshCompletion() async {
        guard let conn = AppModel.shared.connected else { return }
        var words: [String] = Array(SqlHighlight.keywords)
        let withCols = conn.tables.count <= 80
        for t in conn.tables {
            words.append(t.name)
            guard withCols else { continue }
            if let cols = try? await conn.driver.listColumns(database: conn.currentDatabase, table: t.name) {
                words.append(contentsOf: cols.map(\.name))
            }
        }
        completionWords = Array(Set(words)).sorted()
    }
}
