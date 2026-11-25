import AppKit
import SwiftUI

/// The author's Everforest themes (github.com/Haruno19/everforest-vscode):
/// Higure in dark mode, Yoake in light mode. Colours are the themes' own.
struct CodeTheme {
    let dark: Bool

    var background: Color { dark ? Color(hex: 0x131313) : Color(hex: 0xFFFAEE) }
    var border: Color { dark ? Color(hex: 0x272E33) : Color(hex: 0xEFE6CF) }
    var text: Color { dark ? Color(hex: 0xD3C6AA) : Color(hex: 0x5C6A72) }
    var comment: Color { Color(hex: 0x859289) }
    var red: Color { dark ? Color(hex: 0xE67E80) : Color(hex: 0xF85552) }
    var orange: Color { dark ? Color(hex: 0xE69875) : Color(hex: 0xF57D26) }
    var yellow: Color { dark ? Color(hex: 0xDBBC7F) : Color(hex: 0xDFA000) }
    var green: Color { dark ? Color(hex: 0xA7C080) : Color(hex: 0x8DA101) }
    var aqua: Color { dark ? Color(hex: 0x83C092) : Color(hex: 0x35A77C) }
    var blue: Color { dark ? Color(hex: 0x7FBBB3) : Color(hex: 0x3A94C5) }
    var purple: Color { dark ? Color(hex: 0xD699B6) : Color(hex: 0xDF69BA) }

    /// The scopes the themes colour, mapped from the highlighter's tokens.
    func color(_ token: CodeToken) -> Color {
        switch token {
        case .plain: text
        case .keyword: red
        case .declaration, .operator, .tag: orange
        case .type: blue
        case .function, .inserted: green
        case .string: yellow
        case .number, .variable: purple
        case .comment: comment
        case .module, .attribute: aqua
        case .key: orange
        case .deleted: red
        case .section: purple
        }
    }
}

/// A fenced code block: the language and a copy button above the code,
/// which scrolls sideways instead of wrapping.
struct CodeBlock: View {
    let language: String?
    let code: String
    let size: CGFloat
    @Environment(\.palette) private var palette
    @State private var copied = false

    var body: some View {
        let theme = CodeTheme(dark: palette.dark)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language?.lowercased() ?? "code")
                    .font(Typeface.sans(11.5))
                    .foregroundStyle(theme.comment)
                Spacer(minLength: 8)
                Button(action: copy) {
                    HStack(spacing: 4) {
                        PencilIcon(glyph: copied ? .check : .copy, size: 12, color: theme.comment, weight: 1.4)
                        Text(copied ? "Copied" : "Copy").font(Typeface.sans(11.5)).foregroundStyle(theme.comment)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .modifier(HoverWash(shape: RoundedRectangle(cornerRadius: 6, style: .continuous)))
                    .animation(Tune.status, value: copied)
                }
                .buttonStyle(Squish())
            }
            .padding(.leading, 13)
            .padding(.trailing, 7)
            .padding(.top, 6)

            ScrollView(.horizontal) {
                Text(Highlighter.highlighted(code, language: language, theme: theme))
                    .font(Typeface.mono(size))
                    .lineSpacing(3)
                    .fixedSize()
                    .padding(.horizontal, 13)
                    .padding(.top, 3)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
        .background(shape.fill(theme.background))
        .overlay(shape.strokeBorder(theme.border, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(Tune.copied))
            copied = false
        }
    }
}
