import SwiftUI
import AppKit

/// SQL 语法着色器：手写扫描（关键字/字符串/数字/注释/标识符）
enum SqlHighlight {
    static let keywords = Set([
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "VIEW", "INDEX", "DROP", "ALTER", "ADD", "COLUMN", "RENAME",
        "PRIMARY", "KEY", "NOT", "NULL", "AUTOINCREMENT", "AUTO_INCREMENT", "DEFAULT",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "ON", "AS", "AND", "OR", "IN", "LIKE", "BETWEEN", "IS",
        "DISTINCT", "COUNT", "SUM", "AVG", "MIN", "MAX", "BEGIN", "COMMIT", "ROLLBACK",
        "TRANSACTION", "PRAGMA", "SHOW", "DESCRIBE", "EXPLAIN", "USE", "DATABASE",
        "UNION", "ALL", "CASE", "WHEN", "THEN", "ELSE", "END", "WITH", "REFERENCES",
        "FOREIGN", "CONSTRAINT", "UNIQUE", "CHECK", "INT", "INTEGER", "TEXT", "REAL",
        "BLOB", "VARCHAR", "CHAR", "BOOLEAN", "DATE", "DATETIME", "TIMESTAMP", "DOUBLE",
        "FLOAT", "BIGINT", "SMALLINT", "IF", "EXISTS", "MODIFY",
    ])

    /// 按 UTF-16 unit 扫描，range 与 NSAttributedString 坐标一致
    static func attributed(_ sql: String, baseFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: sql)
        let ns = sql as NSString
        let n = ns.length
        var i = 0

        func ch(_ k: Int) -> unichar { ns.character(at: k) }
        func apply(_ from: Int, _ len: Int, _ c: NSColor, bold: Bool = false) {
            out.addAttributes([
                .foregroundColor: c,
                .font: bold ? NSFont(name: "Menlo-Bold", size: baseFont.pointSize) ?? baseFont : baseFont,
            ], range: NSRange(location: from, length: len))
        }
        func isDigit(_ u: unichar) -> Bool { (48...57).contains(u) }
        func isWord(_ u: unichar) -> Bool { (65...90).contains(u) || (97...122).contains(u) || (48...57).contains(u) || u == 95 || u == 36 }

        while i < n {
            let c = ch(i)
            // 行注释 --
            if c == 45, i + 1 < n, ch(i + 1) == 45 {
                var j = i
                while j < n, ch(j) != 10 { j += 1 }
                apply(i, j - i, .secondaryLabelColor)
                i = j
                continue
            }
            // 块注释 /* */
            if c == 47, i + 1 < n, ch(i + 1) == 42 {
                var j = i + 2
                while j + 1 < n, !(ch(j) == 42 && ch(j + 1) == 47) { j += 1 }
                j = min(n, j + 2)
                apply(i, j - i, .tertiaryLabelColor)
                i = j
                continue
            }
            // 引号字符串/标识符
            if c == 39 || c == 34 || c == 96 {
                var j = i + 1
                while j < n {
                    if ch(j) == c {
                        if j + 1 < n, ch(j + 1) == c { j += 2; continue }
                        j += 1
                        break
                    }
                    if ch(j) == 92, c == 39, j + 1 < n { j += 2; continue }
                    j += 1
                }
                apply(i, j - i, c == 39 ? .systemRed : .systemTeal)
                i = j
                continue
            }
            // 数字
            if isDigit(c) {
                var j = i
                while j < n, isDigit(ch(j)) || ch(j) == 46 { j += 1 }
                apply(i, j - i, .systemPurple)
                i = j
                continue
            }
            // 单词（关键字着色）
            if (65...90).contains(c) || (97...122).contains(c) || c == 95 {
                var j = i
                while j < n, isWord(ch(j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(word.uppercased()) {
                    apply(i, j - i, NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.9, alpha: 1), bold: true)
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }
}

/// NSTextView 子类：拦截 ⌘↵（执行）与 ESC（补全面板）
final class SqlTextView: NSTextView {
    var onRun: (() -> Void)?
    var completionWords: [String] = []

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onRun?()
            return
        }
        if event.keyCode == 53 { // ESC → 补全
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// 取当前插入点前的词
    private func currentPrefix() -> String {
        let pos = selectedRange().location
        let text = string as NSString
        var start = pos
        while start > 0 {
            let ch = Character(UnicodeScalar(text.character(at: start - 1)) ?? " ")
            if ch.isLetter || ch.isNumber || ch == "_" { start -= 1 } else { break }
        }
        return text.substring(with: NSRange(location: start, length: pos - start))
    }

    /// NSTextView 官方补全 override 点（complete(_:) → 此方法）
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        let prefix = currentPrefix()
        guard !prefix.isEmpty else { return nil }
        let lower = prefix.lowercased()
        let hits = completionWords.filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
        return hits.isEmpty ? nil : Array(hits.prefix(50))
    }
}

/// SwiftUI 包装的 SQL 编辑器
struct SqlEditor: NSViewRepresentable {
    @Binding var text: String
    var completionWords: [String]
    /// 参数为编辑器当前选中文本（无选区传空串，执行侧回退全文）
    var onRun: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = SqlTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.font = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.insertionPointColor = .labelColor
        tv.textContainerInset = NSSize(width: 6, height: 8)
        let coordinator = context.coordinator
        tv.onRun = { [weak tv, weak coordinator] in
            guard let tv, let coordinator else { return }
            let ns = tv.string as NSString
            let r = tv.selectedRange()
            let sel = r.length > 0 ? ns.substring(with: r) : ""
            coordinator.fireRun(sel)
        }
        tv.completionWords = completionWords
        tv.string = text
        scroll.documentView = tv
        coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SqlTextView else { return }
        tv.completionWords = completionWords
        // 外部替换（如历史复用回填）时同步，避免打字期间重写导致插入点跳动
        if tv.window?.firstResponder !== tv, tv.string != text {
            tv.string = text
            SqlHighlighter.rehighlight(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SqlEditor
        weak var textView: SqlTextView?

        init(_ parent: SqlEditor) { self.parent = parent }

        func fireRun(_ selection: String) { parent.onRun(selection) }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? SqlTextView else { return }
            parent.text = tv.string
            SqlHighlighter.rehighlight(tv)
        }
    }
}

enum SqlHighlighter {
    static func rehighlight(_ tv: NSTextView) {
        guard let lm = tv.layoutManager, let ts = tv.textStorage else { return }
        let font = tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attr = SqlHighlight.attributed(tv.string, baseFont: font)
        ts.setAttributedString(attr)
        lm.ensureLayout(for: tv.textContainer!)
    }
}
