import SwiftUI

// Model replies as Markdown. Foundation's own parser (CommonMark with GitHub's
// tables and strikethrough) reads the text; each run carries its block
// structure as a `PresentationIntent`, which is turned back into a tree of
// blocks here and drawn with SwiftUI.

/// One block of a reply.
indirect enum MarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(language: String?, String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, [MarkdownListItem])
    case table(MarkdownTable)
    case rule
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
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Parsed(blocks), forKey: text as NSString)
        return blocks
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

    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.size == b.size }

    var body: some View {
        MarkdownBlocks(blocks: Markdown.blocks(text), size: size)
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

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
                .font(Typeface.serif(size))
                .lineSpacing(size / 3)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(inline(text))
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

    private func inline(_ text: AttributedString) -> AttributedString {
        Markdown.styleInline(text, size: size, palette: palette)
    }
}

extension Markdown {
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
        Text(Markdown.styleInline(text, size: size * 0.93, palette: palette))
            .font(Typeface.serif(size * 0.93).weight(bold ? .semibold : .regular))
            .lineSpacing(3)
            .padding(.vertical, 6)
            .padding(.trailing, 22)
            .gridColumnAlignment(column < table.alignments.count ? table.alignments[column] : .leading)
    }
}
