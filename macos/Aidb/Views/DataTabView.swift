import SwiftUI

/// 数据网格标签：分页/排序/WHERE 筛选/内联编辑回写/增删行/导出
struct DataTabView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: DataTabModel
    @FocusState private var focusedCell: String?
    @State private var editingText = ""

    private let rowHeight: CGFloat = 24
    private let rownumWidth: CGFloat = 48
    private let opsWidth: CGFloat = 70

    init(tabId: UUID, database: String?, table: String) {
        _model = StateObject(wrappedValue: DataTabModel(database: database, table: table))
    }

    private func colWidth(_ col: ColumnInfo) -> CGFloat {
        let base = CGFloat(max(col.name.count, col.dataType.count) + 4) * 8
        return min(280, max(120, base))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            pageBar
            if let err = model.error { banner(err, color: .red) }
            if let note = model.notice { banner(note, color: .green) }
            grid
        }
        .task { await model.load() }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(color.opacity(0.1))
    }

    // MARK: 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("WHERE 条件（如 id > 10 AND name LIKE 'a%'）", text: $model.whereInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .onSubmit { Task { await model.applyFilter() } }
            Button("过滤") { Task { await model.applyFilter() } }

            Spacer()

            if model.hasDirty {
                Text("\(model.dirtyCount) 处未保存")
                    .font(.callout).foregroundStyle(.orange)
                Button("放弃") { model.discardEdits() }
                Button("保存 ⌘S") { Task { await model.save() } }
                    .keyboardShortcut("s")
                    .disabled(!model.editable)
            }
            Button("+ 行") { model.addRow() }.disabled(!model.editable)
            Button("复制行") { model.duplicateSelection() }
                .disabled(!model.editable || model.selection == nil)
                .help("把选中行复制为一条新增行（跳过自增主键）")
            if model.selection != nil {
                let isDeleted: Bool = {
                    if case .row(let r)? = model.selection { return model.deletedIdx.contains(r) }
                    return false
                }()
                Button(isDeleted ? "恢复选中行" : "删除选中行") { model.deleteSelection() }
                    .foregroundStyle(isDeleted ? Color.primary : Color.red)
            }
            Menu("导出") {
                Button("CSV（全表条件内）") { export(.csv) }
                Button("JSON") { export(.json) }
            }
        }
        .padding(6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 分页条

    private var pageBar: some View {
        HStack(spacing: 10) {
            Picker("每页", selection: $model.pageSize) {
                ForEach([50, 100, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 90)
            .onChange(of: model.pageSize) { Task { await model.gotoPage(0) } }

            Button("‹") { Task { await model.gotoPage(model.page - 1) } }
                .disabled(model.page == 0)
            Text("第 \(model.page + 1) 页 · 共 \(max(1, Int((model.total - 1) / Int64(model.pageSize) + 1))) 页 · 总 \(model.total) 行")
                .font(.callout).foregroundStyle(.secondary)
            Button("›") { Task { await model.gotoPage(model.page + 1) } }
                .disabled(Int64((model.page + 1) * model.pageSize) >= model.total)
            Button("刷新") { Task { await model.load() } }
            if !model.editable {
                Text("无主键 · 只读").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 网格

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                headerRow
                Divider()
                ForEach(model.rows.indices, id: \.self) { r in
                    dataRow(r)
                    Divider()
                }
                ForEach(model.newRows.indices, id: \.self) { n in
                    newRow(n)
                    Divider()
                }
            }
        }
        .overlay {
            if model.loading {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cell(Text("#"), width: rownumWidth, align: .center)
            ForEach(model.columns) { c in
                Button {
                    Task { await model.sortBy(col: c.name) }
                } label: {
                    HStack(spacing: 4) {
                        Text(c.name)
                            .fontWeight(model.orderCol == c.name ? .bold : .regular)
                            .foregroundStyle(c.pkPos != nil ? Color.accentColor : Color.primary)
                        Text(c.dataType).font(.caption2).foregroundStyle(.secondary)
                        if model.orderCol == c.name {
                            Image(systemName: model.orderAsc ? "chevron.up" : "chevron.down").font(.caption2)
                        }
                    }
                    .frame(width: colWidth(c), alignment: .leading)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(c.dataType)\(c.notNull ? " NOT NULL" : "")\(c.pkPos != nil ? " PK" : "")")
            }
            cell(Text("操作"), width: opsWidth, align: .center)
        }
        .frame(height: rowHeight + 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func cell<T: View>(_ content: T, width: CGFloat, align: HorizontalAlignment) -> some View {
        content.frame(width: width, alignment: align == .center ? .center : .leading)
    }

    private func dataRow(_ r: Int) -> some View {
        let deleted = model.deletedIdx.contains(r)
        let sel = model.selection == .row(r)
        return HStack(spacing: 0) {
            cell(Text("\(r + 1 + model.page * model.pageSize)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(deleted ? .red : sel ? Color.accentColor : .secondary), width: rownumWidth, align: .center)
                .background(cellBackgroundColor(deleted: deleted, sel: sel))
                .onTapGesture { model.selection = .row(r) }
            ForEach(model.columns) { c in
                dataCell(r, c)
                    .background(cellBackground(r: r, col: c.name, deleted: deleted, sel: sel))
            }
            cell(
                Button(deleted ? "恢复" : "删除") { model.toggleDelete(row: r) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(deleted ? Color.accentColor : Color.red),
                width: opsWidth, align: .center
            )
            .background(cellBackgroundColor(deleted: deleted, sel: sel))
        }
        .frame(height: rowHeight)
    }

    private func cellBackground(r: Int, col: String, deleted: Bool, sel: Bool) -> Color {
        if deleted { return Color.red.opacity(0.10) }
        if model.isDirty(row: r, col: col) { return sel ? Color.orange.opacity(0.30) : Color.orange.opacity(0.20) }
        if sel { return Color.accentColor.opacity(0.12) }
        return r % 2 == 0 ? .clear : Color.gray.opacity(0.06)
    }

    private func cellBackgroundColor(deleted: Bool, sel: Bool) -> Color {
        if deleted { return Color.red.opacity(0.10) }
        if sel { return Color.accentColor.opacity(0.12) }
        return .clear
    }

    @ViewBuilder
    private func dataCell(_ r: Int, _ c: ColumnInfo) -> some View {
        let key = "\(r).\(c.name)"
        let v = model.value(row: r, col: c.name)
        if model.editingCell?.row == r && model.editingCell?.col == c.name {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($focusedCell, equals: key)
                .frame(width: colWidth(c), alignment: .leading)
                .padding(.horizontal, 6)
                .onSubmit { model.commitEdit(row: r, col: c.name, text: editingText) }
                .onChange(of: focusedCell) { newValue in
                    if newValue != key, case let (er, ec)? = model.editingCell, er == r, ec == c.name {
                        model.commitEdit(row: r, col: c.name, text: editingText)
                    }
                }
        } else {
            Text(v.isNull ? "NULL" : v.display)
                .italic(v.isNull)
                .foregroundStyle(v.isNull ? Color.secondary : (c.dataType.uppercased().contains("INT") ? Color.blue.opacity(0.85) : Color.primary))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: colWidth(c), alignment: .leading)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    // 单击：选中整行并进入编辑
                    model.selection = .row(r)
                    guard model.editable, v.textValue != nil || v.isNull else { return }
                    editingText = v.isNull ? "" : v.display
                    model.editingCell = (r, c.name)
                    focusedCell = key
                }
        }
    }

    private func newRow(_ n: Int) -> some View {
        let sel = model.selection == .newRow(n)
        return HStack(spacing: 0) {
            cell(Text("+").font(.system(.caption, design: .monospaced)).foregroundStyle(.green),
                 width: rownumWidth, align: .center)
                .background(sel ? Color.accentColor.opacity(0.18) : Color.green.opacity(0.12))
                .onTapGesture { model.selection = .newRow(n) }
            ForEach(model.columns) { c in
                let val = model.newRows[n][c.name]
                TextField(c.pkPos != nil ? "（主键自动）" : "", text: Binding(
                    get: { val?.display ?? "" },
                    set: { model.updateNewRow(n, col: c.name, text: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .disabled(c.pkPos != nil)
                .frame(width: colWidth(c), alignment: .leading)
                .padding(.horizontal, 6)
                .background(sel ? Color.accentColor.opacity(0.10) : Color.green.opacity(0.06))
            }
            cell(Button("移除") { model.newRows.remove(at: n) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.red),
                width: opsWidth, align: .center)
        }
        .frame(height: rowHeight)
    }

    // MARK: 导出（当前过滤条件内全量）

    private enum Format { case csv, json }

    private func export(_ format: Format) {
        guard let conn = app.connected else { return }
        let t = SqlSafety.quoteIdent(kind: conn.driver.kind, model.table)
        let filter = model.whereApplied.map { " WHERE \($0)" } ?? ""
        let order = model.orderCol.map { " ORDER BY \(SqlSafety.quoteIdent(kind: conn.driver.kind, $0)) \(model.orderAsc ? "ASC" : "DESC")" } ?? ""
        Task {
            do {
                let r = try await conn.driver.runStatement(database: model.database, sql: "SELECT * FROM \(t)\(filter)\(order)")
                let name = "\(model.table).\(format == .csv ? "csv" : "json")"
                guard let url = Exporter.savePanel(defaultName: name) else { return }
                let text = format == .csv
                    ? Exporter.csvText(columns: r.columns, rows: r.rows)
                    : Exporter.jsonText(columns: r.columns, rows: r.rows)
                try Exporter.write(text, to: url)
                model.notice = "已导出 \(url.path)"
            } catch {
                model.error = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}
