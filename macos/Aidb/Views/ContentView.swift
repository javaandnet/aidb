import SwiftUI

/// 主界面：侧栏库表树 + 多标签工作区 + 全局工具栏/弹窗
struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            WorkspaceView()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("选择连接…") { app.showConnectionManager = true }
                    .help("管理数据库连接")
                Menu {
                    Button("新建查询") { app.newSqlTab() }
                        .keyboardShortcut("n")
                    Button("新建表") { app.openStructureTab(table: nil) }
                    Button("查询历史") { app.openHistoryTab() }
                } label: {
                    Label("新建", systemImage: "plus")
                }
                Button {
                    Task { await app.refreshTree() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(app.connected == nil)
                if let conn = app.connected {
                    Button("断开连接") { app.disconnect() }
                        .help("当前：\(conn.profile.name)")
                }
            }
        }
        .sheet(isPresented: $app.showConnectionManager) {
            ConnectionManagerView()
        }
        .sheet(item: $app.csvImportTarget) { target in
            ImportCsvView(database: target.database, table: target.table)
        }
    }
}
