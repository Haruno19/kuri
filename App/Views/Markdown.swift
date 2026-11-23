import SwiftUI

// Model replies as Markdown. Foundation's own parser (CommonMark with GitHub's
// tables and strikethrough) reads the text; each run carries its block
// structure as a `PresentationIntent`, which is turned back into a tree of
// blocks here and drawn with SwiftUI. LaTeX is lifted out before parsing
// (Markdown would read its `_` and `*`), left as placeholders, and drawn by
// `MathRenderer`.

/// One block of a reply.
indirect enum MarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(language: String?, String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, [MarkdownListItem])
    case table(MarkdownTable)
    case rule
    /// A paragraph holding only display maths: an index into the document's maths.
    case math(Int)
}

/// A formula found in a reply.
struct MarkdownMath {
    let tex: String
    let display: Bool
}

/// A parsed reply: its blocks, and the maths their placeholders point to.
struct MarkdownDocument {
    let blocks: [MarkdownBlock]
    let math: [MarkdownMath]
}

extension EnvironmentValues {
    @Entry var markdownMath: [MarkdownMath] = []
    /// Off in the mini window: `$` stays text there.
    @Entry var allowsMath = true
}

struct MarkdownListItem {
    let ordinal: Int
    /// `- [ ]` and `- [x]`, which Foundation leaves as text.
    let checked: Bool?
    let blocks: [MarkdownBlock]
}

struct MarkdownTable {
    let alignments: [HorizontalAlignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]
}

enum Markdown {
    /// Parsed replies, so earlier messages aren't parsed again on every
    /// streamed token.
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 120
        return cache
    }()

    private final class Parsed {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    static func document(_ text: String, math allowsMath: Bool = true) -> MarkdownDocument {
        let key = ((allowsMath ? "1" : "0") + text) as NSString
        if let hit = cache.object(forKey: key) { return hit.document }
        let (markdown, math) = allowsMath ? extractMath(text) : (text, [])
        let document = MarkdownDocument(blocks: parse(markdown), math: math)
        cache.setObject(Parsed(document), forKey: key)
        return document
    }

    /// Marks a formula's place in the text; private-use characters, so
    /// neither Markdown nor a model would produce them.
    static let mathOpen: Character = "\u{E000}", mathClose: Character = "\u{E001}"

    /// Replaces `$$…$$` and `\[…\]` (display) and `$…$` and `\(…\)`
    /// (inline) with placeholders, leaving code alone. A `$` opens inline
    /// maths only before a non-space and closes it only after one, and not
    /// before a digit, so prices ("$5 and $10") stay text.
    static func extractMath(_ text: String) -> (String, [MarkdownMath]) {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return (text, []) }
        let c = Array(text)
        var out = ""
        var math: [MarkdownMath] = []
        var i = 0
        var inFence = false

        func add(_ from: Int, _ to: Int, display: Bool) {
            math.append(MarkdownMath(tex: String(c[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines), display: display))
            out.append(mathOpen)
            out += String(math.count - 1)
            out.append(mathClose)
        }
        func find(_ pattern: [Character], from: Int) -> Int? {
            var j = from
            while j + pattern.count <= c.count {
                if Array(c[j..<(j + pattern.count)]) == pattern { return j }
                j += 1
            }
            return nil
        }
        func copyLine() {
            while i < c.count && c[i] != "\n" { out.append(c[i]); i += 1 }
            if i < c.count { out.append(c[i]); i += 1 }
        }

        while i < c.count {
            if i == 0 || c[i - 1] == "\n" {
                var j = i
                while j < c.count && c[j] == " " && j - i < 3 { j += 1 }
                let fence = j + 2 < c.count && ((c[j] == "`" && c[j + 1] == "`" && c[j + 2] == "`") || (c[j] == "~" && c[j + 1] == "~" && c[j + 2] == "~"))
                if fence { inFence.toggle(); copyLine(); continue }
                if inFence { copyLine(); continue }
            }
            let ch = c[i]
            if ch == "\\" && i + 1 < c.count {
                if c[i + 1] == "(" || c[i + 1] == "[" {
                    let display = c[i + 1] == "["
                    if let end = find(["\\", display ? "]" : ")"], from: i + 2) {
                        add(i + 2, end, display: display)
                        i = end + 2
                        continue
                    }
                }
                out.append(ch)
                out.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "`" {
                var n = 0
                while i + n < c.count && c[i + n] == "`" { n += 1 }
                let run = Array(repeating: Character("`"), count: n)
                if let end = find(run, from: i + n) {
                    out += String(c[i..<(end + n)])
                    i = end + n
                } else {
                    out += String(run)
                    i += n
                }
                continue
            }
            if ch == "$" {
                if i + 1 < c.count && c[i + 1] == "$" {
                    if let end = find(["$", "$"], from: i + 2), end > i + 2 {
                        add(i + 2, end, display: true)
                        i = end + 2
                        continue
                    }
                } else if i + 1 < c.count && !c[i + 1].isWhitespace {
                    var j = i + 1
                    while j < c.count && c[j] != "\n" {
                        if c[j] == "$" && !c[j - 1].isWhitespace && c[j - 1] != "\\"
                            && !(j + 1 < c.count && (c[j + 1].isNumber || c[j + 1] == "$")) { break }
                        j += 1
                    }
                    if j < c.count && c[j] == "$" {
                        add(i + 1, j, display: false)
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(ch)
            i += 1
        }
        return (out, math)
    }

    /// A node of the block tree while it's being rebuilt from the runs.
    private final class Box {
        let kind: PresentationIntent.Kind?
        let identity: Int
        var children: [Box] = []
        var text = AttributedString()
        init(kind: PresentationIntent.Kind?, identity: Int) {
            self.kind = kind
            self.identity = identity
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let string = try? AttributedString(markdown: text, options: options) else {
            return [.paragraph(AttributedString(text))]
        }
        let root = Box(kind: nil, identity: -1)
        for run in string.runs {
            var box = root
            // Components go from the innermost block outwards.
            let components = run.presentationIntent?.components.reversed() ?? []
            if components.isEmpty {
                if let last = root.children.last, last.kind == nil { box = last } else {
                    box = Box(kind: nil, identity: -2)
                    root.children.append(box)
                }
            }
            for component in components {
                if let last = box.children.last, last.identity == component.identity {
                    box = last
                } else {
                    let child = Box(kind: component.kind, identity: component.identity)
                    box.children.append(child)
                    box = child
                }
            }
            var piece = AttributedString(string[run.range])
            piece.presentationIntent = nil
            // Replies are written for a chat, not for reflowing: a single
            // newline is meant as one.
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                piece = AttributedString("\n")
            }
            box.text.append(piece)
        }
        return blocks(root.children)
    }

    private static func blocks(_ boxes: [Box]) -> [MarkdownBlock] {
        boxes.flatMap { box -> [MarkdownBlock] in
            switch box.kind {
            case .paragraph?, nil:
                if let index = soleDisplayMath(box.text) { return [.math(index)] }
                return [.paragraph(box.text)]
            case .header(let level)?:
                return [.heading(level: level, box.text)]
            case .codeBlock(let hint)?:
                var code = String(box.text.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                return [.code(language: hint?.isEmpty == false ? hint : nil, code)]
            case .thematicBreak?:
                return [.rule]
            case .blockQuote?:
                return [.quote(blocks(box.children))]
            case .orderedList?, .unorderedList?:
                let ordered = if case .orderedList? = box.kind { true } else { false }
                return [.list(ordered: ordered, box.children.map(item))]
            case .table(let columns)?:
                return [.table(table(box, columns: columns))]
            default:
                return blocks(box.children) + (box.text.characters.isEmpty ? [] : [.paragraph(box.text)])
            }
        }
    }

    /// The index of a paragraph that is nothing but one formula.
    private static func soleDisplayMath(_ text: AttributedString) -> Int? {
        let string = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.first == mathOpen, string.last == mathClose else { return nil }
        return Int(string.dropFirst().dropLast())
    }

    private static func item(_ box: Box) -> MarkdownListItem {
        var ordinal = 1
        if case .listItem(let n)? = box.kind { ordinal = n }
        var content = blocks(box.children)
        var checked: Bool?
        if case .paragraph(let text)? = content.first {
            let start = String(text.characters.prefix(4))
            if start == "[ ] " || start == "[x] " || start == "[X] " {
                checked = start != "[ ] "
                var rest = text
                rest.removeSubrange(rest.startIndex..<rest.index(rest.startIndex, offsetByCharacters: 4))
                content[0] = .paragraph(rest)
            }
        }
        return MarkdownListItem(ordinal: ordinal, checked: checked, blocks: content)
    }

    private static func table(_ box: Box, columns: [PresentationIntent.TableColumn]) -> MarkdownTable {
        func cells(_ row: Box) -> [AttributedString] {
            var out = Array(repeating: AttributedString(), count: columns.count)
            for cell in row.children {
                if case .tableCell(let column)? = cell.kind, column < out.count { out[column] = cell.text }
            }
            return out
        }
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        for row in box.children {
            if case .tableHeaderRow? = row.kind { header = cells(row) } else { rows.append(cells(row)) }
        }
        let alignments = columns.map { column -> HorizontalAlignment in
            switch column.alignment {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }
}

// MARK: - Views

/// A reply: serif, straight on the surface.
struct MarkdownView: View, Equatable {
    let text: String
    var size: CGFloat = 15
    @Environment(\.palette) private var palette
    @Environment(\.allowsMath) private var allowsMath

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.size == b.size }

    var body: some View {
        let document = Markdown.document(text, math: allowsMath)
        MarkdownBlocks(blocks: document.blocks, size: size)
            .environment(\.markdownMath, document.math)
            .foregroundStyle(palette.ink)
            .tint(palette.accent)
            .textSelection(.enabled)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.75) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, size: size)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.markdownMath) private var math

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text, size: size)
                .font(Typeface.serif(size))
                .lineSpacing(size / 3)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            inline(text, size: headingSize(level))
                .font(Typeface.serif(headingSize(level)).weight(level <= 2 ? .semibold : .bold))
                .lineSpacing(2)
                .padding(.top, level <= 2 ? size * 0.5 : size * 0.2)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            CodeBlock(language: language, code: code, size: size * Typeface.monoScale)

        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, size: size)
                .foregroundStyle(palette.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(palette.accent.opacity(0.45)).frame(width: 2.5)
                }

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: size * 0.4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item, ordered: ordered)
                        MarkdownBlocks(blocks: item.blocks, size: size)
                    }
                }
            }
            .padding(.leading, 4)

        case .table(let table):
            MarkdownTableView(table: table, size: size)

        case .math(let index):
            DisplayMath(math: index < math.count ? math[index] : nil, size: size)

        case .rule:
            Rectangle()
                .fill(palette.faint.opacity(0.35))
                .frame(height: 1)
                .padding(.vertical, size * 0.4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: size * 1.47
        case 2: size * 1.27
        case 3: size * 1.13
        default: size
        }
    }

    @ViewBuilder private func marker(_ item: MarkdownListItem, ordered: Bool) -> some View {
        if let checked = item.checked {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(palette.faint, lineWidth: 1.2)
                if checked { PencilIcon(glyph: .check, size: 11, color: palette.accent, weight: 1.6) }
            }
            .frame(width: 13, height: 13)
            .alignmentGuide(.firstTextBaseline) { $0.height - 1.5 }
        } else if ordered {
            Text("\(item.ordinal).")
                .font(Typeface.serif(size))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text("•")
                .font(Typeface.serif(size))
                .foregroundStyle(palette.faint)
                .frame(minWidth: 10)
        }
    }

    private func inline(_ text: AttributedString, size: CGFloat) -> Text {
        Markdown.text(text, size: size, palette: palette, math: math)
    }
}

extension Markdown {
    /// Inline text with its formulas drawn in place, sitting on the baseline.
    static func text(_ text: AttributedString, size: CGFloat, palette: Palette, math: [MarkdownMath]) -> Text {
        let styled = styleInline(text, size: size, palette: palette)
        guard !math.isEmpty, styled.characters.contains(mathOpen) else { return Text(styled) }
        var pieces: [Text] = []
        var cursor = styled.startIndex
        while let open = styled.characters[cursor...].firstIndex(of: mathOpen),
              let close = styled.characters[open...].firstIndex(of: mathClose) {
            pieces.append(Text(AttributedString(styled[cursor..<open])))
            let label = String(styled.characters[styled.characters.index(after: open)..<close])
            if let index = Int(label), index < math.count {
                let formula = math[index]
                if let rendered = MathRenderer.shared.render(formula.tex, display: formula.display, size: size, color: palette.ink) {
                    pieces.append(Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.depth))
                } else {
                    pieces.append(Text(formula.tex).font(Typeface.mono(size * Typeface.monoScale)))
                }
            }
            cursor = styled.characters.index(after: close)
        }
        pieces.append(Text(AttributedString(styled[cursor...])))
        // Joined by interpolation: `Text + Text` is deprecated.
        return pieces.dropFirst().reduce(pieces[0]) { Text("\($0)\($1)") }
    }

    /// Inline code in the mono face, smaller, on a faint wash.
    static func styleInline(_ text: AttributedString, size: CGFloat, palette: Palette) -> AttributedString {
        var text = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = Typeface.mono(size * Typeface.monoScale)
            text[run.range].backgroundColor = palette.ink.opacity(palette.dark ? 0.09 : 0.06)
        }
        return text
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let size: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.markdownMath) private var math

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, bold: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(palette.faint.opacity(0.3)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column, bold: false)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
    }

    private func cellView(_ text: AttributedString, column: Int, bold: Bool) -> some View {
        Markdown.text(text, size: size * 0.93, palette: palette, math: math)
            .font(Typeface.serif(size * 0.93).weight(bold ? .semibold : .regular))
            .lineSpacing(3)
            .padding(.vertical, 6)
            .padding(.trailing, 22)
            .gridColumnAlignment(column < table.alignments.count ? table.alignments[column] : .leading)
    }
}

/// A formula on its own line, centred; wide ones scroll sideways.
private struct DisplayMath: View {
    let math: MarkdownMath?
    let size: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        if let math, let rendered = MathRenderer.shared.render(math.tex, display: true, size: size, color: palette.ink) {
            let image = Image(nsImage: rendered.image).padding(.vertical, 2)
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal) { image }.scrollIndicators(.automatic)
            }
        } else if let math {
            Text(math.tex)
                .font(Typeface.mono(size * Typeface.monoScale))
                .foregroundStyle(palette.secondary)
                .textSelection(.enabled)
        }
    }
}
