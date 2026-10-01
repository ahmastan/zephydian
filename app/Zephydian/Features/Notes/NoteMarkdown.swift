import SwiftUI

/// The Markdown a note preview understands: headings, lists, checkboxes, quotes, code blocks and
/// rules, line by line. Bold, italic, `code` and links inside a line come from Apple's own parser.
/// Anything else shows as it was typed. The note itself always stays plain text.
enum NoteMarkdown {
    enum Kind: Equatable {
        case heading(level: Int)
        case task(checked: Bool)
        case bullet
        case numbered(String)
        case quote
        case code
        case rule
        case paragraph
    }

    struct Block: Identifiable, Equatable {
        /// The line the block starts on (a task's line is what ticking it changes).
        let line: Int
        let kind: Kind
        let text: String
        var indent = 0
        var id: Int { line }
    }

    static func blocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = indentLevel(raw)

            if line.isEmpty {
                i += 1
            } else if line.hasPrefix("```") {
                // A fenced code block runs to the closing fence (or the end of the note).
                let start = i
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(Block(line: start, kind: .code, text: code.joined(separator: "\n")))
            } else if let level = headingLevel(line) {
                blocks.append(Block(line: i, kind: .heading(level: level), text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                i += 1
            } else if isRule(line) {
                blocks.append(Block(line: i, kind: .rule, text: ""))
                i += 1
            } else if let box = checkboxRange(in: raw) {
                let rest = raw[box.upperBound...].dropFirst()  // after "]"
                blocks.append(Block(line: i, kind: .task(checked: raw[box] != " "), text: rest.trimmingCharacters(in: .whitespaces), indent: indent))
                i += 1
            } else if let rest = bulletText(line) {
                blocks.append(Block(line: i, kind: .bullet, text: rest, indent: indent))
                i += 1
            } else if let (number, rest) = numberedText(line) {
                blocks.append(Block(line: i, kind: .numbered(number), text: rest, indent: indent))
                i += 1
            } else if line.hasPrefix(">") {
                let start = i
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(Block(line: start, kind: .quote, text: quote.joined(separator: "\n")))
            } else {
                // A paragraph keeps its line breaks (notes are usually written line by line).
                let start = i
                var para: [String] = []
                while i < lines.count, startsParagraphLine(lines[i]) {
                    para.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(Block(line: start, kind: .paragraph, text: para.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// The character between the brackets of a `- [ ]` / `* [x]` / `+ [X]` line.
    static func checkboxRange(in line: String) -> Range<String.Index>? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.count >= 5, let marker = trimmed.first, "-*+".contains(marker) else { return nil }
        let chars = Array(trimmed.prefix(6))
        guard chars[1] == " ", chars[2] == "[", " xX".contains(chars[3]), chars[4] == "]",
              chars.count == 5 || chars[5] == " " else { return nil }
        let box = line.index(trimmed.startIndex, offsetBy: 3)
        return box..<line.index(after: box)
    }

    /// Bold, italic, code and links; plain text if it isn't valid Markdown.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 4 } else { break }
        }
        return min(spaces / 2, 6)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func bulletText(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first), line.dropFirst().first == " " else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func numberedText(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return ("\(digits)\(mark)", String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    /// Whether a line continues a paragraph (it isn't blank and doesn't start another block).
    private static func startsParagraphLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        return !line.isEmpty && !line.hasPrefix("```") && headingLevel(line) == nil && !isRule(line)
            && checkboxRange(in: raw) == nil && bulletText(line) == nil && numberedText(line) == nil && !line.hasPrefix(">")
    }
}

/// A note, formatted. Checkboxes can be ticked, which changes `[ ]` to `[x]` in the note.
struct NotePreview: View {
    let text: String
    let fontSize: CGFloat
    let monospaced: Bool
    let onToggle: (Int) -> Void

    var body: some View {
        let blocks = NoteMarkdown.blocks(text)
        ScrollView {
            if blocks.isEmpty {
                Text("Nothing to preview yet. Switch back to write something.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: fontSize * 0.5) {
                    ForEach(blocks) { block($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 5)   // lines up with the editor's text
                .textSelection(.enabled)
            }
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Note preview")
    }

    private var bodyFont: Font {
        monospaced ? .system(size: fontSize - 0.5, design: .monospaced) : .system(size: fontSize)
    }

    @ViewBuilder
    private func block(_ block: NoteMarkdown.Block) -> some View {
        let inline = NoteMarkdown.inline(block.text)
        switch block.kind {
        case .heading(let level):
            let scale: CGFloat = [1.5, 1.3, 1.15, 1.05, 1, 1][level - 1]
            Text(inline)
                .font(.system(size: fontSize * scale, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? fontSize * 0.4 : fontSize * 0.2)
                .accessibilityAddTraits(.isHeader)
        case .task(let checked):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Button { onToggle(block.line) } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: fontSize + 1))
                        .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(checked ? "Checked" : "Not checked")
                .accessibilityHint("Toggles this item")
                Text(inline)
                    .font(bodyFont)
                    .strikethrough(checked)
                    .foregroundStyle(checked ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(block.indent) * 16)
        case .bullet:
            listRow(marker: "•", inline: inline, indent: block.indent)
        case .numbered(let number):
            listRow(marker: number, inline: inline, indent: block.indent)
        case .quote:
            Text(inline)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint.opacity(0.6)).frame(width: 3)
                }
        case .code:
            Text(block.text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.fill))
        case .rule:
            Divider().padding(.vertical, 4)
        case .paragraph:
            Text(inline).font(bodyFont).lineSpacing(2)
        }
    }

    private func listRow(marker: String, inline: AttributedString, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).font(bodyFont.monospacedDigit()).foregroundStyle(.secondary)
            Text(inline).font(bodyFont)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }
}
