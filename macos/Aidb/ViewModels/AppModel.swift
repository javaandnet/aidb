import SwiftUI

/// 工作区标签描述
struct TabSpec: Identifiable, Equatable {
    enum Kind: Equatable { case data, sql, structure, history, newTable }
    let id: UUID
    var kind: Kind
    var title: String
    var database: String?
    var table: String?
    /// SQL 标签的预填语句（历史复用入口）
    var presetSQL: String?

    static func == (lhs: TabSpec, rhs: TabSpec) -> Bool { lhs.id == rhs.id }
}

/// 当前活动连接
struct ConnectedDB {
    let profile: ConnectionProfile
    let driver: any DbDriver
    var databases: [String]
    var currentDatabase: String?
    var tables: [TableInfo] = []
}

/// 全局应用状态：连接档案、活动连接、库表树、多标签工作区。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var profiles: [ConnectionProfile] = []
    @Published var connected: ConnectedDB?
    @Published var tabs: [TabSpec] = []
    @Published var activeTabId: UUID?
    @Published var showConnectionManager = false
    @Published var sidebarFilter = ""
    /// 树刷新代次，供子视图监听
    @Published var schemaVersion = 0
    /// 非 nil 时 ContentView 弹出 CSV 导入向导 sheet
    @Published var csvImportTarget: CsvImportTarget?

    struct CsvImportTarget: Identifiable {
        let id = UUID()
        let database: String?
        let table: String
    }

    private init() {
        profiles = ConfigStore.shared.listConnections()
    }

    var kind: DatabaseKind? { connected?.profile.kind }

    // MARK: - 档案与连接

    func refreshProfiles() { profiles = ConfigStore.shared.listConnections() }

    func saveProfile(_ profile: ConnectionProfile, password: String?) {
        ConfigStore.shared.saveConnection(profile, password: password)
        refreshProfiles()
    }

    func deleteProfile(id: String) {
        if connected?.profile.id == id { disconnect() }
        ConfigStore.shared.deleteConnection(id: id)
        refreshProfiles()
    }

    func password(for profile: ConnectionProfile) -> String? {
        ConfigStore.shared.password(for: profile)
    }

    func makeDriver(_ profile: ConnectionProfile, password: String?) throws -> any DbDriver {
        switch profile.kind {
        case .sqlite:
            guard let path = profile.path, !path.isEmpty else {
                throw DriverError.message("未选择数据库文件")
            }
            return try SqliteDriver(path: (path as NSString).expandingTildeInPath)
        case .mysql:
            return try MysqlDriver(
                host: profile.host ?? "127.0.0.1",
                port: UInt16(profile.port ?? 3306),
                user: profile.user ?? "",
                password: password ?? "",
                database: profile.database
            )
        }
    }

    func testConnection(_ profile: ConnectionProfile, password: String?) async -> Result<String, Error> {
        do {
            let driver = try makeDriver(profile, password: password)
            let info = try await driver.test()
            return .success(info)
        } catch {
            return .failure(error)
        }
    }

    func connect(_ profile: ConnectionProfile) async throws {
        let driver = try makeDriver(profile, password: password(for: profile))
        let version = try await driver.test()
        NSLog("aidb: connected \(profile.name) (\(version))")
        let dbs = (try? await driver.listDatabases()) ?? []
        var current = profile.database
        if profile.kind == .sqlite { current = "main" }
        var conn = ConnectedDB(profile: profile, driver: driver, databases: dbs, currentDatabase: current)
        conn.tables = (try? await driver.listTables(database: current)) ?? []
        connected = conn
        schemaVersion += 1
        // 关闭旧连接的标签？——保留策略与 TablePlus 一致：切连接时清空标签
        tabs.removeAll()
        activeTabId = nil
    }

    func disconnect() {
        connected = nil
        tabs.removeAll()
        activeTabId = nil
        schemaVersion += 1
    }

    func switchDatabase(_ name: String) async {
        guard var conn = connected else { return }
        conn.currentDatabase = name
        conn.tables = (try? await conn.driver.listTables(database: name)) ?? []
        connected = conn
        schemaVersion += 1
    }

    func refreshTree() async {
        guard var conn = connected else { return }
        if conn.profile.kind == .mysql {
            conn.databases = (try? await conn.driver.listDatabases()) ?? conn.databases
        }
        conn.tables = (try? await conn.driver.listTables(database: conn.currentDatabase)) ?? []
        connected = conn
        schemaVersion += 1
    }

    var tables: [TableInfo] {
        let all = connected?.tables ?? []
        let q = sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    func columnsOf(_ table: String, database: String? = nil) async throws -> [ColumnInfo] {
        guard let conn = connected else { throw DriverError.message("未连接") }
        return try await conn.driver.listColumns(database: database ?? conn.currentDatabase, table: table)
    }

    // MARK: - 标签

    @discardableResult
    func openDataTab(table: String, database: String?) -> UUID {
        let title = database.map { "\($0).\(table)" } ?? table
        // 已有同表数据标签则激活
        if let exist = tabs.first(where: { $0.kind == .data && $0.table == table && $0.database == database }) {
            activeTabId = exist.id
            return exist.id
        }
        let spec = TabSpec(id: UUID(), kind: .data, title: title, database: database, table: table)
        tabs.append(spec)
        activeTabId = spec.id
        return spec.id
    }

    @discardableResult
    func newSqlTab(presetSQL: String? = nil) -> UUID {
        let spec = TabSpec(id: UUID(), kind: .sql, title: presetSQL == nil ? "未命名查询" : "复用查询",
                           database: connected?.currentDatabase, table: nil, presetSQL: presetSQL)
        tabs.append(spec)
        activeTabId = spec.id
        return spec.id
    }

    @discardableResult
    func openStructureTab(table: String?) -> UUID {
        let title = table.map { "结构 · \($0)" } ?? "新建表"
        let spec = TabSpec(id: UUID(), kind: table == nil ? .newTable : .structure, title: title, database: connected?.currentDatabase, table: table)
        tabs.append(spec)
        activeTabId = spec.id
        return spec.id
    }

    @discardableResult
    func openHistoryTab() -> UUID {
        if let exist = tabs.first(where: { $0.kind == .history }) {
            activeTabId = exist.id
            return exist.id
        }
        let spec = TabSpec(id: UUID(), kind: .history, title: "查询历史", database: nil, table: nil)
        tabs.append(spec)
        activeTabId = spec.id
        return spec.id
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabId == id { activeTabId = tabs.last?.id }
    }

    func renameTab(_ id: UUID, title: String) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].title = title }
    }
}
