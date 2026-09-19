import SwiftUI

/// 网格选中行：数据行 / 新增行
enum GridSelection: Equatable {
    case row(Int)
    case newRow(Int)
}

/// 数据标签状态机：分页/排序/筛选/脏格/增删行/回写（对应 Tauri 版 DataTab.vue）
@MainActor
final class DataTabModel: ObservableObject {
    let database: String?
    let table: String

    @Published var columns: [ColumnInfo] = []
    @Published var rows: [[GridValue]] = []
    @Published var total: Int64 = 0
    @Published var page = 0
    @Published var pageSize = 100
    @Published var orderCol: String?
    @Published var orderAsc = true
    @Published var whereInput = ""
    @Published var whereApplied: String?
    @Published var loading = false
    @Published var error: String?
    @Published var notice: String?

    // 编辑状态
    @Published var edits: [String: GridValue] = [:]      // key "rowIdx.colName"
    @Published var newRows: [[String: GridValue]] = []
    @Published var deletedIdx: Set<Int> = []
    @Published var editingCell: (row: Int, col: String)?
    @Published var selection: GridSelection?

    init(database: String?, table: String) {
        self.database = database
        self.table = table
    }

    var pkCols: [ColumnInfo] { columns.filter { $0.pkPos != nil } }
    var editable: Bool { !pkCols.isEmpty }

    var dirtyCount: Int { edits.count + newRows.count + deletedIdx.count }

    var hasDirty: Bool { !edits.isEmpty || !newRows.isEmpty || !deletedIdx.isEmpty }

    func colIndex(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }

    /// 当前显示值（原始行 + 编辑覆盖）
    func value(row: Int, col: String) -> GridValue {
        if let v = edits["\(row).\(col)"] { return v }
        return rows[row][colIndex(col) ?? 0]
    }

    func isDirty(row: Int, col: String) -> Bool { edits["\(row).\(col)"] != nil }

    /// 提交内联编辑：按列类型推断 GridValue
    func commitEdit(row: Int, col: String, text: String) {
        editingCell = nil
        let original = rows[row][colIndex(col) ?? 0]
        let next: GridValue
        if text.isEmpty {
            // 用户显式清空输入 → NULL（TablePlus 习惯）
            next = .null
        } else {
            switch original {
            case .integer: next = Int64(text).map(GridValue.integer) ?? .text(text)
            case .uinteger: next = UInt64(text).map(GridValue.uinteger) ?? .text(text)
            case .real: next = Double(text).map(GridValue.real) ?? .text(text)
            case .null:
                if let i = Int64(text) { next = .integer(i) }
                else if let d = Double(text) { next = .real(d) }
                else { next = .text(text) }
            default: next = .text(text)
            }
        }
        let key = "\(row).\(col)"
        if next == original { edits[key] = nil } else { edits[key] = next }
    }

    func addRow() {
        newRows.append([:])
    }

    /// 复制选中行为新增行：跳过单列整型主键（让库自增），blob/NULL 不复制
    func duplicateSelection() {
        guard editable else { return }
        var obj: [String: GridValue] = [:]
        let skipPk = pkCols.count == 1 && pkCols[0].dataType.uppercased().contains("INT")
        switch selection {
        case .row(let r):
            guard r < rows.count else { return }
            for c in columns {
                if skipPk && c.pkPos != nil { continue }
                let v = value(row: r, col: c.name)
                if v.isNull || v.textValue == nil { continue } // blob 不复制
                obj[c.name] = v
            }
        case .newRow(let n):
            guard n < newRows.count else { return }
            obj = newRows[n]
        case nil:
            return
        }
        newRows.append(obj)
        selection = .newRow(newRows.count - 1)
    }

    /// 删除/恢复选中行（新增行直接移除）
    func deleteSelection() {
        switch selection {
        case .row(let r):
            toggleDelete(row: r)
        case .newRow(let n):
            guard n < newRows.count else { return }
            newRows.remove(at: n)
            selection = nil
        case nil:
            break
        }
    }

    func isSelected(_ sel: GridSelection) -> Bool { selection == sel }

    func updateNewRow(_ idx: Int, col: String, text: String) {
        let trimmed = text
        if trimmed.isEmpty {
            newRows[idx][col] = nil
        } else if let colInfo = columns.first(where: { $0.name == col }) {
            let t = colInfo.dataType.uppercased()
            if t.contains("INT"), let i = Int64(trimmed) { newRows[idx][col] = .integer(i) }
            else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB"), let d = Double(trimmed) { newRows[idx][col] = .real(d) }
            else { newRows[idx][col] = .text(trimmed) }
        } else {
            newRows[idx][col] = .text(trimmed)
        }
    }

    func toggleDelete(row: Int) {
        if deletedIdx.contains(row) { deletedIdx.remove(row) } else { deletedIdx.insert(row) }
    }

    func discardEdits() {
        edits.removeAll()
        newRows.removeAll()
        deletedIdx.removeAll()
        editingCell = nil
        selection = nil
    }

    // MARK: 加载与保存

    func load() async {
        guard let conn = AppModel.shared.connected else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            if columns.isEmpty {
                columns = try await conn.driver.listColumns(database: database, table: table)
            }
            let pageResult = try await conn.driver.queryPage(
                database: database, table: table,
                page: page, pageSize: pageSize,
                orderCol: orderCol, orderAsc: orderAsc,
                whereSql: whereApplied
            )
            rows = pageResult.result.rows
            total = pageResult.total
            discardEdits()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func applyFilter() async {
        let w = whereInput.trimmingCharacters(in: .whitespacesAndNewlines)
        whereApplied = w.isEmpty ? nil : w
        page = 0
        await load()
    }

    func sortBy(col: String) async {
        if orderCol == col { orderAsc.toggle() } else { orderCol = col; orderAsc = true }
        await load()
    }

    func gotoPage(_ p: Int) async {
        guard p >= 0 else { return }
        let maxPage = max(0, Int((total - 1) / Int64(pageSize)))
        page = min(p, maxPage)
        await load()
    }

    /// 构建变更集（供预览与执行）
    func buildChanges() -> TableChanges {
        var ch = TableChanges()
        // updates：按行聚合 edits
        var byRow: [Int: [(String, GridValue)]] = [:]
        for (key, v) in edits {
            let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard let r = Int(parts[0]) else { continue }
            byRow[r, default: []].append((String(parts[1]), v))
        }
        for (r, setVals) in byRow.sorted(by: { $0.key < $1.key }) {
            guard r < rows.count else { continue }
            let pk = pkCols.map { c in (c.name, rows[r][colIndex(c.name) ?? 0]) }
            ch.updates.append(RowChange(pk: pk, set: setVals))
        }
        // inserts：跳过全空行
        for nr in newRows {
            let cols = nr.map { ($0.key, $0.value) }.sorted { a, b in
                (colIndex(a.0) ?? 0) < (colIndex(b.0) ?? 0)
            }
            if !cols.isEmpty { ch.inserts.append(cols) }
        }
        // deletes
        for r in deletedIdx.sorted() {
            guard r < rows.count else { continue }
            ch.deletes.append(pkCols.map { c in (c.name, rows[r][colIndex(c.name) ?? 0]) })
        }
        return ch
    }

    func save() async {
        guard let conn = AppModel.shared.connected else { return }
        guard editable else { error = "无主键表只读展示"; return }
        let changes = buildChanges()
        guard !changes.isEmpty else { return }
        error = nil
        notice = nil
        do {
            let affected = try await conn.driver.applyChanges(database: database, table: table, changes: changes)
            notice = "已保存，影响 \(affected) 行"
            await load()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}
