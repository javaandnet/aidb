import SwiftUI
import AppKit

/// aidb macOS 原生版入口。
@main
struct AidbApp: App {
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("aidb") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建查询") { app.newSqlTab() }
                    .keyboardShortcut("n")
                Button("新建表") { app.openStructureTab(table: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("管理连接…") { app.showConnectionManager = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("aidb 使用说明") {
                    if let url = URL(string: "https://github.com/javaandnet/aidb") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
