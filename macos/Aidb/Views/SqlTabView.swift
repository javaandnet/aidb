import SwiftUI

/// SQL 查询标签：编辑器（⌘↵ 选中优先）+ 多结果 tab + 状态栏
struct SqlTabView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: SqlTabModel
    @State private var editorHeight: CGFloat = 180

    init(spec: TabSpec) {
        _model = StateObject(wrappedValue: SqlTabModel(spec: spec))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SqlEditor(text: $model.sql, completionWords: model.completionWords) { sel in
                Task { await model.run(selected: sel) }
            }
            .frame(height: editorHeight)
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            resultsArea
                .frame(minHeight: 120)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task { await model.refreshCompletion() }
        .onChange(of: app.schemaVersion) { _ in
            Task { await model.refreshCompletion() }
        }
    }

    // MARK: 顶部条

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.run(selected: "") }
            } label: {
                Label("执行 ⌘↵", systemImage: "play.fill")
            }
            .disabled(model.isRunning)
            if model.isRunning {
                ProgressView().controlSize(.small)
            }
            Text("选中片段优先执行 · ESC 唤出补全")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if let s = model.statusText {
                Text(s).font(.callout).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refreshCompletion() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新补全（表/列名）")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 结果区

    private var resultsArea: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("尚未执行查询").foregroundStyle(.tertiary)
                    Text("编写 SQL 后按 ⌘↵ 执行；选中文本时只执行选中部分")
                        .font(.caption).foregroundStyle(.quaternary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    resultTabs
                    Divider()
                    activeContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var resultTabs: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let active = item.id == model.activeItem?.id
                Button {
                    model.activeItemID = item.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(item.ok ? Color.green : Color.red).font(.caption)
                        Text("语句 \(i + 1) · \(item.ms)ms").font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(active ? Color.accentColor.opacity(0.15) : .clear)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(active ? Color.accentColor.opacity(0.5) : .clear))
                }
                .buttonStyle(.plain)
                .help(item.statement)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var activeContent: some View {
        if let item = model.activeItem, item.ok, let result = item.result {
            ResultGridView(result: result)
        } else if let item = model.activeItem {
            VStack(alignment: .leading, spacing: 8) {
                Text("语句：\(item.statement)")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(item.error ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}
