import SwiftUI
import AppKit

/// 表结构标签：列列表 + 加列/改名/删列 + 索引 + DDL；table 为 nil 时为建表表单
struct StructureTabView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: StructureModel

    init(database: String?, table: String?, tabId: UUID) {
        _model = StateObject(wrappedValue: StructureModel(database: database, table: table))
    }

    var body: some View {
        Group {
            if model.table == nil {
                createForm
            } else {
                editor
            }
        }
        .task { await model.load() }
    }

    // MARK: - 既有表：结构编辑

    private var editor: some View {
        VStack(spacing: 0) {
            toolbar
            if let err = model.error { banner(err, color: .red) }
            if let note = model.notice { banner(note, color: .green) }
            HSplitView {
                columnsPane.frame(minWidth: 380)
                rightPane.frame(minWidth: 300)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $model.showAddColumn) { addColumnSheet }
        .sheet(item: $model.renameTarget) { col in renameSheet(col) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("列 (\(model.columns.count))").font(.callout.weight(.medium))
            Button("+ 列") { model.beginAddColumn() }
            Button("刷新") { Task { await model.load() } }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(color.opacity(0.1))
    }

    private var columnsPane: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    head("列名", 160); head("类型", 110); head("NN", 34); head("默认值", 100)
                    head("PK", 34); head("操作", 130)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ForEach(model.columns) { c in
                    HStack(spacing: 0) {
                        cell(Text(c.name).font(.system(.body, design: .monospaced)), 160)
                        cell(Text(c.dataType).foregroundStyle(.secondary), 110)
                        cell(Text(c.notNull ? "✓" : ""), 34)
                        cell(Text(c.defaultValue ?? "").lineLimit(1), 100)
                        cell(Text(c.pkPos.map(String.init) ?? ""), 34)
                        cell(HStack(spacing: 6) {
                            Button("改名") { model.renameTarget = c }
                            Button("删除", role: .destructive) { confirmDrop(c) }
                        }, 130)
                    }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func head(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.callout.weight(.medium)).frame(width: w, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func cell<C: View>(_ content: C, _ w: CGFloat) -> some View {
        content.frame(width: w, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 3)
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("索引").font(.callout.weight(.medium)).padding(8)
            Divider()
            if let idx = model.indexResult {
                ResultGridView(result: idx, displayLimit: 100)
                    .frame(maxHeight: 180)
            } else {
                Text("—").foregroundStyle(.tertiary).padding(8)
            }
            Divider()
            HStack {
                Text("DDL").font(.callout.weight(.medium))
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.ddl, forType: .string)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                Text(model.ddl)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    // MARK: 加列 / 改名 / 删列

    private var addColumnSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加列").font(.headline)
            TextField("列名", text: $model.newColName)
            TextField("类型（TEXT / INTEGER / REAL / BLOB…）", text: $model.newColType)
            Toggle("NOT NULL", isOn: $model.newColNotNull)
            TextField("默认值（可空）", text: $model.newColDefault)
            HStack {
                Spacer()
                Button("取消") { model.showAddColumn = false }
            Button("执行…") {
                model.showAddColumn = false
                if let sql = model.addColumnSQL() { confirmRun(sql) }
            }
            .disabled(model.newColName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func renameSheet(_ col: ColumnInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重命名列 “\(col.name)”").font(.headline)
            TextField("新列名", text: $model.renameNewName)
                .onAppear { model.renameNewName = col.name }
            HStack {
                Spacer()
                Button("取消") { model.renameTarget = nil }
                Button("执行…") {
                    if let sql = model.renameColumnSQL(old: col.name, new: model.renameNewName) {
                        model.renameTarget = nil
                        confirmRun(sql)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func confirmDrop(_ col: ColumnInfo) {
        guard let sql = model.dropColumnSQL(col.name) else { return }
        confirmRun(sql)
    }

    /// 展示待执行 SQL，确认后立即执行
    private func confirmRun(_ sql: String) {
        let a = NSAlert()
        a.messageText = "执行以下 SQL？"
        a.informativeText = sql
        a.addButton(withTitle: "执行")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            Task { await model.runDDL(sql) }
        }
    }

    // MARK: - 新建表

    private var createForm: some View {
        VStack(spacing: 0) {
            toolbarNew
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("表名").frame(width: 60, alignment: .leading)
                        TextField("my_table", text: $model.newTableName).frame(maxWidth: 300)
                    }
                    Text("列定义").font(.callout.weight(.medium))
                    ForEach($model.newTableCols) { $c in
                        HStack(spacing: 8) {
                            TextField("列名", text: $c.name).frame(width: 140)
                            TextField("类型", text: $c.type).frame(width: 110)
                            Toggle("NN", isOn: $c.notNull).toggleStyle(.checkbox)
                            Toggle("PK", isOn: $c.isPk).toggleStyle(.checkbox)
                            TextField("默认值", text: $c.defaultText).frame(width: 100)
                            Button(role: .destructive) {
                                model.newTableCols.removeAll { $0.id == c.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                    }
                    Button("+ 添加列") { model.newTableCols.append(NewColumn()) }
                        .padding(.horizontal, 10)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbarNew: some View {
        HStack(spacing: 8) {
            Text("新建表").font(.callout.weight(.medium))
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button("生成并执行 CREATE TABLE…") {
                if let sql = model.createTableSQL() { confirmRun(sql) }
            }
            .disabled(model.newTableName.trimmingCharacters(in: .whitespaces).isEmpty
                       || model.newTableCols.isEmpty)
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 建表表单里的一行列定义
struct NewColumn: Identifiable {
    let id = UUID()
    var name = ""
    var type = "TEXT"
    var notNull = false
    var isPk = false
    var defaultText = ""
}

/// 结构标签状态机：列/索引/DDL 加载 + ALTER/CREATE SQL 生成与执行
@MainActor
final class StructureModel: ObservableObject {
    let database: String?
    let table: String?

    @Published var columns: [ColumnInfo] = []
    @Published var ddl = ""
    @Published var indexResult: QueryResult?
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?

    // 加列表单
    @Published var showAddColumn = false
    @Published var newColName = ""
    @Published var newColType = "TEXT"
    @Published var newColNotNull = false
    @Published var newColDefault = ""
    // 改名单元（Identifiable 供 sheet(item:) 使用）
    @Published var renameTarget: ColumnInfo?
    @Published var renameNewName = ""
    // 建表
    @Published var newTableName = ""
    @Published var newTableCols: [NewColumn] = [NewColumn()]

    init(database: String?, table: String?) {
        self.database = database
        self.table = table
    }

    private var kind: DatabaseKind { AppModel.shared.kind ?? .sqlite }
    private var qualifiedTable: String {
        guard let table else { return "" }
        return SqlSafety.quoteQualified(kind: kind, schema: database, table: table)
    }

    func load() async {
        guard let conn = AppModel.shared.connected, let table else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            columns = try await conn.driver.listColumns(database: database, table: table)
            ddl = try await conn.driver.tableDDL(database: database, table: table)
            let idxSQL: String
            if kind == .sqlite {
                idxSQL = "PRAGMA index_list(\(SqlSafety.quoteIdent(kind: .sqlite, table)))"
            } else {
                idxSQL = "SHOW INDEX FROM \(qualifiedTable)"
            }
            indexResult = try? await conn.driver.runStatement(database: database, sql: idxSQL)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginAddColumn() {
        newColName = ""; newColType = "TEXT"; newColNotNull = false; newColDefault = ""
        showAddColumn = true
    }

    func addColumnSQL() -> String? {
        let n = newColName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let table else { return nil }
        var sql = "ALTER TABLE \(qualifiedTable) ADD COLUMN \(SqlSafety.quoteIdent(kind: kind, n)) \(newColType)"
        if !newColDefault.isEmpty { sql += " DEFAULT \(literal(newColDefault))" }
        if newColNotNull { sql += " NOT NULL" }
        return sql
    }

    func renameColumnSQL(old: String, new: String) -> String? {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old, table != nil else { return nil }
        return "ALTER TABLE \(qualifiedTable) RENAME COLUMN \(SqlSafety.quoteIdent(kind: kind, old)) TO \(SqlSafety.quoteIdent(kind: kind, n))"
    }

    func dropColumnSQL(_ name: String) -> String? {
        guard table != nil else { return nil }
        // SQLite ≥3.35 / MySQL 8 均原生支持 DROP COLUMN
        return "ALTER TABLE \(qualifiedTable) DROP COLUMN \(SqlSafety.quoteIdent(kind: kind, name))"
    }

    func createTableSQL() -> String? {
        let t = newTableName.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let quotedT = SqlSafety.quoteIdent(kind: kind, t)
        var parts: [String] = []
        var pks: [String] = []
        for c in newTableCols {
            let n = c.name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            var def = SqlSafety.quoteIdent(kind: kind, n) + " " + (c.type.isEmpty ? "TEXT" : c.type)
            if c.isPk { pks.append(n) }
            if c.notNull { def += " NOT NULL" }
            if !c.defaultText.isEmpty { def += " DEFAULT " + literal(c.defaultText) }
            parts.append(def)
        }
        guard !parts.isEmpty else { return nil }
        // 单列主键内联，复合主键表级约束
        if pks.count == 1, !parts.contains(where: { $0.hasPrefix(SqlSafety.quoteIdent(kind: kind, pks[0]) + " ") && $0.contains("PRIMARY KEY") }) {
            if let i = parts.firstIndex(where: { $0.hasPrefix(SqlSafety.quoteIdent(kind: kind, pks[0]) + " ") }) {
                parts[i] += " PRIMARY KEY"
            }
        } else if pks.count > 1 {
            parts.append("PRIMARY KEY (" + pks.map { SqlSafety.quoteIdent(kind: kind, $0) }.joined(separator: ", ") + ")")
        }
        return "CREATE TABLE \(quotedT) (\n  " + parts.joined(separator: ",\n  ") + "\n)"
    }

    /// 字面量：数字直写，字符串单引号翻倍转义
    private func literal(_ s: String) -> String {
        if Double(s) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func runDDL(_ sql: String) async {
        guard let conn = AppModel.shared.connected else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            _ = try await conn.driver.runStatement(database: database, sql: sql)
            notice = "已执行：\(sql.split(separator: "\n").first.map(String.init) ?? sql) …"
            ConfigStore.shared.addHistory(sql: sql, durationMs: nil, rowCount: nil, error: nil)
            if table == nil {
                // 建表成功后关表单、转列表视图并刷树
                await AppModel.shared.refreshTree()
                AppModel.shared.tabs.removeAll { $0.kind == .newTable }
                AppModel.shared.openStructureTab(table: newTableName.trimmingCharacters(in: .whitespaces))
            } else {
                await load()
                await AppModel.shared.refreshTree()
            }
        } catch {
            self.error = "执行失败：\(error.localizedDescription)"
            ConfigStore.shared.addHistory(sql: sql, durationMs: nil, rowCount: nil, error: error.localizedDescription)
        }
    }
}
