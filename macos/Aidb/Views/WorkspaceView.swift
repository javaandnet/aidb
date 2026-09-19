import SwiftUI

/// 右侧多标签工作区：自定义标签条 + 内容分发
struct WorkspaceView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if app.tabs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("aidb").font(.system(size: 40, weight: .light, design: .rounded)).foregroundStyle(.quaternary)
                    Text("选择连接后，从左侧点击表浏览数据，或按 ⌘N 新建查询")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabBar
                Divider()
                content
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(app.tabs) { tab in
                    let active = tab.id == app.activeTabId
                    HStack(spacing: 4) {
                        Image(systemName: iconFor(tab.kind)).font(.caption).foregroundStyle(active ? Color.accentColor : .secondary)
                        Text(tab.title).lineLimit(1)
                        Button {
                            app.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(active ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { app.activeTabId = tab.id }
                    .contextMenu {
                        Button("关闭标签") { app.closeTab(tab.id) }
                        Button("关闭其他") {
                            app.tabs.removeAll { $0.id != tab.id }
                            app.activeTabId = tab.id
                        }
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func iconFor(_ kind: TabSpec.Kind) -> String {
        switch kind {
        case .data: return "tablecells"
        case .sql: return "curlybraces"
        case .structure: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .newTable: return "plus.rectangle.on.folder"
        }
    }

    /// 所有标签常挂载（保状态），仅活动标签可见可交互
    private var content: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            ForEach(app.tabs) { tab in
                tabView(tab)
                    .opacity(tab.id == app.activeTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == app.activeTabId)
            }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: TabSpec) -> some View {
        switch tab.kind {
        case .data:
            if let table = tab.table {
                DataTabView(tabId: tab.id, database: tab.database, table: table)
            }
        case .sql:
            SqlTabView(spec: tab)
        case .structure:
            StructureTabView(database: tab.database, table: tab.table ?? "", tabId: tab.id)
        case .newTable:
            StructureTabView(database: tab.database, table: nil, tabId: tab.id)
        case .history:
            HistoryTabView()
        }
    }
}
