import SwiftUI
import AppKit

/// 连接管理：档案列表 + 新建/编辑表单 + 测试连接（对应 Tauri 版 ConnectionManager.vue）
struct ConnectionManagerView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    struct EditorState {
        var isNew = false
        var name = ""
        var kind: DatabaseKind = .sqlite
        var path = ""
        var host = "127.0.0.1"
        var port = "3306"
        var user = "root"
        var password = ""
        var database = ""
    }

    @State private var editor: EditorState?
    @State private var testMessage: String?
    @State private var testing = false

    var body: some View {
        Group {
            if let ed = editor {
                editorView(ed)
            } else {
                listView
            }
        }
        .frame(width: 560, height: 420)
        .padding()
    }

    // MARK: 列表

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("连接管理").font(.headline)
                Spacer()
                Button("+ 新建连接") {
                    editor = EditorState()
                    testMessage = nil
                }
            }
            .padding(.bottom, 10)

            if app.profiles.isEmpty {
                Text("还没有连接档案，点击「新建连接」开始")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 60)
            } else {
                List {
                    ForEach(app.profiles) { p in
                        HStack(spacing: 10) {
                            Image(systemName: p.kind == .sqlite ? "doc" : "server.rack")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body.weight(.medium))
                                Text(p.target).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if app.connected?.profile.id == p.id {
                                Text("已连接").font(.caption2).foregroundStyle(.green)
                            }
                            Button("连接") { Task { await connectNow(p) } }
                                .disabled(app.connected?.profile.id == p.id)
                            Button("编辑") { startEdit(p) }
                            Button("删除", role: .destructive) {
                                if confirmDelete(p) { app.deleteProfile(id: p.id) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Spacer()
            if let msg = testMessage {
                Text(msg).font(.callout)
                    .foregroundStyle(msg.hasPrefix("✓") ? Color.green : Color.red)
                    .textSelection(.enabled)
                    .padding(.bottom, 6)
            }
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
            }
        }
    }

    private func confirmDelete(_ p: ConnectionProfile) -> Bool {
        let alert = NSAlert()
        alert.messageText = "删除连接档案「\(p.name)」？"
        alert.informativeText = "仅删除档案与 Keychain 中的密码，不影响数据库文件。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func connectNow(_ p: ConnectionProfile) async {
        do {
            try await app.connect(p)
            dismiss()
        } catch {
            testMessage = "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: 编辑器

    private func startEdit(_ p: ConnectionProfile) {
        editor = EditorState(
            isNew: false,
            name: p.name,
            kind: p.kind,
            path: p.path ?? "",
            host: p.host ?? "127.0.0.1",
            port: String(p.port ?? 3306),
            user: p.user ?? "root",
            password: app.password(for: p) ?? "",
            database: p.database ?? ""
        )
        // 用 id 记录编辑目标
        editingId = p.id
        testMessage = nil
    }

    @State private var editingId: String?

    private func editorView(_ ed: EditorState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editingId == nil ? "新建连接" : "编辑连接").font(.headline)
                Spacer()
            }

            Picker("类型", selection: Binding(
                get: { editor?.kind ?? .sqlite },
                set: { editor?.kind = $0 }
            )) {
                Text("SQLite").tag(DatabaseKind.sqlite)
                Text("MySQL").tag(DatabaseKind.mysql)
            }
            .pickerStyle(.segmented).labelsHidden()

            if ed.kind == .sqlite {
                HStack {
                    TextField("数据库文件路径", text: Binding(
                        get: { editor?.path ?? "" },
                        set: { editor?.path = $0 }
                    ))
                    Button("浏览…") { pickFile() }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("主机"); TextField("host", text: bindHost).gridCellColumns(3)
                    }
                    GridRow {
                        Text("端口"); TextField("3306", text: bindPort)
                        Text("用户"); TextField("root", text: bindUser)
                    }
                    GridRow {
                        Text("密码"); SecureField("password", text: bindPassword).gridCellColumns(3)
                    }
                    GridRow {
                        Text("数据库"); TextField("可留空，连接后再选", text: bindDatabase).gridCellColumns(3)
                    }
                }
            }

            HStack {
                Text("名称")
                TextField("连接名称", text: bindName)
            }

            if let msg = testMessage {
                Text(msg).font(.callout)
                    .foregroundStyle(msg.hasPrefix("✓") ? Color.green : Color.red)
                    .textSelection(.enabled)
            }

            Spacer()
            HStack {
                Button(testing ? "测试中…" : "测试连接") { Task { await runTest(ed) } }
                    .disabled(testing)
                Spacer()
                Button("取消") { editor = nil; editingId = nil }
                Button("保存") { Task { await save(ed) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 SQLite 数据库文件（不存在将新建）"
        if panel.runModal() == .OK, let url = panel.url {
            editor?.path = url.path
        }
    }

    private var bindName: Binding<String> { Binding(get: { editor?.name ?? "" }, set: { editor?.name = $0 }) }
    private var bindHost: Binding<String> { Binding(get: { editor?.host ?? "" }, set: { editor?.host = $0 }) }
    private var bindPort: Binding<String> { Binding(get: { editor?.port ?? "" }, set: { editor?.port = $0 }) }
    private var bindUser: Binding<String> { Binding(get: { editor?.user ?? "" }, set: { editor?.user = $0 }) }
    private var bindPassword: Binding<String> { Binding(get: { editor?.password ?? "" }, set: { editor?.password = $0 }) }
    private var bindDatabase: Binding<String> { Binding(get: { editor?.database ?? "" }, set: { editor?.database = $0 }) }

    private func buildProfile(_ ed: EditorState) -> ConnectionProfile {
        var p: ConnectionProfile
        if let id = editingId, let old = app.profiles.first(where: { $0.id == id }) {
            p = old
            p.name = ed.name
            p.kind = ed.kind
        } else {
            p = ConnectionProfile(name: ed.name, kind: ed.kind)
        }
        switch ed.kind {
        case .sqlite:
            p.path = ed.path
            p.host = nil; p.port = nil; p.user = nil; p.database = nil
        case .mysql:
            p.path = nil
            p.host = ed.host
            p.port = Int(ed.port) ?? 3306
            p.user = ed.user
            p.database = ed.database.isEmpty ? nil : ed.database
        }
        return p
    }

    private func runTest(_ ed: EditorState) async {
        testing = true
        testMessage = nil
        let profile = buildProfile(ed)
        let result = await app.testConnection(profile, password: ed.password)
        testing = false
        switch result {
        case .success(let info): testMessage = "✓ 连接成功：\(info)"
        case .failure(let err): testMessage = "✗ \(err.localizedDescription)"
        }
    }

    private func save(_ ed: EditorState) async {
        guard !ed.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            testMessage = "✗ 连接名称不能为空"; return
        }
        if ed.kind == .sqlite, ed.path.trimmingCharacters(in: .whitespaces).isEmpty {
            testMessage = "✗ 请选择数据库文件"; return
        }
        let profile = buildProfile(ed)
        app.saveProfile(profile, password: ed.kind == .mysql ? ed.password : nil)
        editor = nil
        editingId = nil
        // 保存即连接；失败则回到列表并显示原因（不能静默吞掉）
        do {
            try await app.connect(app.profiles.first { $0.id == profile.id } ?? profile)
            dismiss()
        } catch {
            testMessage = "已保存档案，但连接失败：\(error.localizedDescription)"
        }
    }
}
