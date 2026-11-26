import SwiftUI

/// Block-level Markdown, parsed incrementally-safe: an unclosed code fence (mid-stream) is still a
/// code block, so streaming output never flickers between layouts.
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [ListItem])
    case code(language: String?, code: String)
    case quote(String)
    case table(String)
    case rule

    nonisolated struct ListItem: Equatable, Sendable {
        var marker: String   // "•" or "1."
        var indent: Int
        var text: String
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        var code: (language: String?, lines: [String])?

        func flushText() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !listItems.isEmpty { blocks.append(.list(items: listItems)); listItems = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushText()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty {
                flushText()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushText()
                blocks.append(.heading(level: heading, text: trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).isSubset(of: ["-", "*", "_"]),
               Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1 {
                flushText()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !listItems.isEmpty || !quote.isEmpty { flushText() }
                table.append(trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !listItems.isEmpty || !table.isEmpty { flushText() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty { flushText() }
                listItems.append(item)
                continue
            }
            if !listItems.isEmpty, line.hasPrefix("  ") {
                // Continuation line of the previous list item.
                listItems[listItems.count - 1].text += " " + trimmed
                continue
            }
            if !listItems.isEmpty || !quote.isEmpty || !table.isEmpty { flushText() }
            paragraph.append(line)
        }
        if let open = code {
            blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
        }
        flushText()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return ListItem(marker: "•", indent: indent, text: String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(marker: "\(digits).", indent: indent, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}

/// Renders Markdown blocks with inline styling, code blocks with highlighting and a copy button.
struct MarkdownView: View {
    let markdown: String
    let tokens: ThemeTokens
    var copy: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(.system(size: level == 1 ? 15 : level == 2 ? 14 : 13, weight: .bold))
        case .paragraph(let text):
            Self.inline(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(tokens.secondaryText)
                        Self.inline(item.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, tokens: tokens, copy: copy)
        case .quote(let text):
            HStack(spacing: 8) {
                Capsule().fill(tokens.secondaryText.opacity(0.5)).frame(width: 3)
                Self.inline(text).font(.system(size: 12.5).italic()).foregroundStyle(tokens.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 11, design: .monospaced))
            }
        case .rule:
            Divider().overlay(tokens.secondaryText.opacity(0.3))
        }
    }

    /// Bold, italics, `code`, links and strikethrough via Foundation's inline Markdown.
    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let tokens: ThemeTokens
    let copy: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.secondaryText)
                Spacer()
                Button {
                    copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.05))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(size: 11.5, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Lightweight regex highlighter (Xcode dark palette): comments, strings, numbers, keywords.
/// Language-agnostic by design; good enough to make code scannable in a notch.
nonisolated enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "let", "var", "func", "return", "if", "else", "for", "while", "in", "guard", "switch", "case", "default",
        "break", "continue", "class", "struct", "enum", "protocol", "extension", "import", "init", "self", "Self",
        "true", "false", "nil", "null", "None", "True", "False", "def", "from", "as", "with", "lambda", "yield",
        "const", "function", "async", "await", "try", "catch", "throw", "throws", "new", "this", "public",
        "private", "static", "final", "override", "interface", "type", "export", "package", "fn", "pub", "mut",
        "impl", "use", "match", "where", "do", "then", "fi", "echo", "elif", "not", "and", "or", "is", "go",
        "defer", "select", "struct", "val", "fun", "object", "when", "void", "int", "string", "bool",
    ]

    /// One left-to-right scan over strings and comments, so whichever starts first wins
    /// (a quote inside a comment, or "//" inside a string, are both handled).
    private static let stringsAndSlashComments = try! NSRegularExpression(
        pattern: #"("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`)|(//[^\n]*|/\*[\s\S]*?\*/)"#)
    /// Same, plus `#` line comments for languages that use them (shell, Python, Ruby, YAML, …).
    private static let stringsAndAllComments = try! NSRegularExpression(
        pattern: #"("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`)|(//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)"#)
    private static let hashCommentLanguages: Set<String> = [
        "sh", "bash", "zsh", "shell", "console", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "r",
        "perl", "make", "makefile", "dockerfile", "conf", "ini", "nix", "elixir", "ex", "powershell", "ps1",
    ]
    private static let number = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#)
    private static let word = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    private static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.36)
    private static let commentColor = Color(red: 0.50, green: 0.55, blue: 0.60)

    static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = Color(white: 0.92)
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed = IndexSet()

        func color(_ range: NSRange, _ color: Color) {
            guard let swiftRange = Range(range, in: code),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { return }
            result[lower..<upper].foregroundColor = color
        }

        let lang = language?.lowercased()
        let scanner = (lang == nil || hashCommentLanguages.contains(lang!)) ? stringsAndAllComments : stringsAndSlashComments
        for match in scanner.matches(in: code, range: full) {
            let isString = match.range(at: 1).location != NSNotFound
            color(match.range, isString ? stringColor : commentColor)
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }

        func paint(_ regex: NSRegularExpression, _ paintColor: Color, filter: (String) -> Bool = { _ in true }) {
            for match in regex.matches(in: code, range: full) {
                let range = match.range
                guard !claimed.intersects(integersIn: range.location..<(range.location + range.length)),
                      filter(ns.substring(with: range)) else { continue }
                color(range, paintColor)
            }
        }
        paint(number, Color(red: 0.85, green: 0.79, blue: 0.49))
        paint(word, Color(red: 1.0, green: 0.48, blue: 0.70)) { keywords.contains($0) }
        return result
    }
}
