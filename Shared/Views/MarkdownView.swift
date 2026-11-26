import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders a model's Markdown answer for reading: headings, paragraphs, bulleted and numbered lists (nested),
/// code blocks with a Copy button, quotes, tables and rules, with inline bold, italics, code and links.
/// Tolerates half-written Markdown, since answers render while they stream.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

enum MarkdownBlock {
    struct ListItem {
        let level: Int
        let marker: String   // "•" or "3."
        let text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case code(language: String, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        var quote: [String] = []
        var tableLines: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !listItems.isEmpty { blocks.append(.list(listItems)); listItems = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !tableLines.isEmpty { blocks.append(table(tableLines)); tableLines = [] }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            // Fenced code: runs to the closing fence (or the end, while it's still streaming).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && paragraph.isEmpty {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
                if tableLines.isEmpty { flush() }
                tableLines.append(trimmed)
            } else if let item = listItem(trimmed, indent: indent) {
                if listItems.isEmpty { flush() }
                listItems.append(item)
            } else if !listItems.isEmpty && indent >= 2 {
                // A wrapped line belonging to the previous list item.
                let last = listItems.removeLast()
                listItems.append(ListItem(level: last.level, marker: last.marker, text: last.text + " " + trimmed))
            } else {
                if !listItems.isEmpty || !quote.isEmpty || !tableLines.isEmpty { flush() }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String, indent: Int) -> ListItem? {
        let level = min(indent / 2, 4)
        for bullet in ["- ", "* ", "+ ", "• "] where line.hasPrefix(bullet) {
            var text = String(line.dropFirst(2))
            // Task lists: "- [ ] x" / "- [x] x".
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) } else if text.lowercased().hasPrefix("[x] ") { text = "☑︎ " + text.dropFirst(4) }
            return ListItem(level: level, marker: "•", text: text)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(level: level, marker: "\(digits).", text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func table(_ lines: [String]) -> MarkdownBlock {
        func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") { trimmed.removeLast() }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let isSeparator: (String) -> Bool = { line in
            line.allSatisfy { "|-: ".contains($0) } && line.contains("-")
        }
        let rows = lines.filter { !isSeparator($0) }.map(cells)
        guard let header = rows.first else { return .paragraph(lines.joined(separator: "\n")) }
        return .table(header: header, rows: Array(rows.dropFirst()))
    }
}

/// Inline Markdown (bold, italics, `code`, links), keeping line breaks.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.level > 0 && item.marker == "•" ? "◦" : item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: item.marker == "•" ? 8 : 16, alignment: .trailing)
                        Text(inlineMarkdown(item.text))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }

        case .code(let language, let text):
            CodeBlockView(language: language, code: text)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.4)).frame(width: 3)
                Text(inlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inlineMarkdown(cell)).font(.callout.weight(.semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(header.indices), id: \.self) { column in
                                Text(inlineMarkdown(column < row.count ? row[column] : "")).font(.callout)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// A code block: monospaced, scrolls sideways, with the language and a Copy button.
private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToClipboard(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.primary.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
