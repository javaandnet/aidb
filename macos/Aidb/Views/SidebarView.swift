import SwiftUI

/// 左侧库表树：连接→(数据库)→表/视图，懒加载，点击表打开数据标签
struct SidebarView: View {
    @EnvironmentObject var app: AppModel
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            if let conn = app.connected {
                // 连接头 + 库切换
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 8))
                    Text(conn.profile.name).font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)

                if conn.profile.kind == .mysql {
                    Picker("库", selection: Binding(
                        get: { conn.currentDatabase ?? "" },
                        set: { v in Task { await app.switchDatabase(v) } }
                    )) {
                        ForEach(conn.databases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().padding(.horizontal, 8)
                }

                TextField("过滤表名…", text: $app.sidebarFilter)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 8).padding(.vertical, 4)

                List {
                    DisclosureGroup(isExpanded: $expanded) {
                        ForEach(app.tables) { t in
                            Button {
                                app.openDataTab(table: t.name, database: t.schema == "main" ? nil : t.schema)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: t.kind == "view" ? "eye" : "tablecells")
                                        .foregroundStyle(.secondary).font(.caption)
                                    Text(t.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("查看结构") { app.openStructureTab(table: t.name) }
                                Button("新建查询") { app.newSqlTab() }
                                if t.kind != "view" {
                                    Divider()
                                    Button("导入 CSV…") {
                                        app.csvImportTarget = AppModel.CsvImportTarget(
                                            database: t.schema == "main" ? nil : t.schema, table: t.name)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text("表 (\(app.tables.count)) +")
                            .font(.callout.weight(.medium))
                            .help("已隐藏 sqlite_* 等内部表")
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("未连接数据库").foregroundStyle(.secondary)
                    Text("点击左上角「选择连接…」")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Button {
                    app.openHistoryTab()
                } label: {
                    Label("查询历史", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(10)
        }
    }
}
