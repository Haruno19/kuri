import Darwin
import Foundation

/// What you type while kuri waits for you, at the prompt or answering a
/// question. kuri draws the line itself instead of letting the terminal
/// echo it, so a command can be styled as it's typed and a line is kept
/// free under the prompt, even at the bottom of the window. The terminal is
/// in raw mode only meanwhile: during a turn it's back to its own line
/// editing, and a line typed then is queued as before.
final class LineEditor {
    enum Action {
        case submit(String)
        case interrupt
        case endOfInput
    }

    /// What comes before the text: `text` to measure, `styled` to draw.
    struct Prompt {
        let text: String
        let styled: String
    }

    /// How wide a tab is drawn: pasted code can hold them.
    static let tabWidth = 4

    private let stream: Stream
    /// The names that light up as commands while typed.
    private let commands: Set<String>

    private var text: [Character] = []
    private var cursor = 0
    private(set) var isActive = false
    private var hidden = false
    private var prompt = Prompt(text: "", styled: "")
    private var styleCommands = false
    private var usesHistory = false
    /// The cursor's row, counted from the prompt's: where erasing starts.
    private var cursorRow = 0
    /// How the output ended before the prompt, for when it's hidden.
    private var trailingNewlines = 1

    private var history: [String] = []
    private var historyIndex = 0
    private var draft: [Character] = []

    /// Bytes of a key that hasn't fully arrived.
    private var partial: [UInt8] = []
    /// Keys typed after Return in the same burst, or while kuri wasn't
    /// listening: they start the next line.
    private var typeahead: [UInt8] = []
    /// Between the terminal's paste markers: Return is text, not a send.
    private var pasting = false
    private var afterCarriageReturn = false

    init(stream: Stream, commands: Set<String>) {
        self.stream = stream
        self.commands = commands
        // wcwidth gives East Asian and emoji widths only under a UTF-8 locale.
        setlocale(LC_CTYPE, "UTF-8")
    }

    // MARK: Showing

    /// Starts a line after `prompt`, at the start of the current line.
    func begin(_ prompt: Prompt, commands: Bool) {
        self.prompt = prompt
        styleCommands = commands
        usesHistory = commands
        text = []
        cursor = 0
        cursorRow = 0
        historyIndex = history.count
        pasting = false
        isActive = true
        hidden = false
        trailingNewlines = stream.trailingNewlines
        // Bracketed paste: the terminal marks pasted text, so a pasted
        // newline doesn't send the message half-written.
        stream.writeControl("\u{1B}[?2004h")
        render()
    }

    /// Takes the prompt off the screen so output can be written where it was.
    func hide() {
        guard isActive, !hidden else { return }
        stream.writeControl(erase())
        cursorRow = 0
        hidden = true
        stream.restoreTrailingNewlines(trailingNewlines)
    }

    /// Draws the prompt again under whatever was written meanwhile.
    func show() {
        guard isActive, hidden else { return }
        hidden = false
        // As far from the output as it was when it began.
        if trailingNewlines >= 2 { stream.blankLine() } else { stream.endLine() }
        trailingNewlines = stream.trailingNewlines
        render()
    }

    /// Bytes that arrived while kuri wasn't listening.
    func takeTypeahead() -> [UInt8]? {
        defer { typeahead = [] }
        return typeahead.isEmpty ? nil : typeahead
    }

    // MARK: Keys

    /// Applies typed bytes; an action ends the line. Keys after it wait for
    /// the next one.
    func feed(_ bytes: [UInt8]) -> Action? {
        guard isActive else {
            typeahead += bytes
            return nil
        }
        let bytes = partial + bytes
        partial = []
        var index = 0
        var action: Action?
        while index < bytes.count, action == nil {
            let byte = bytes[index]
            if byte == 0x1B {
                guard let (length, key) = Self.escape(in: bytes, at: index) else {
                    partial = Array(bytes[index...])
                    index = bytes.count
                    break
                }
                index += length
                action = apply(key)
            } else if byte < 0x20 || byte == 0x7F {
                index += 1
                action = control(byte)
            } else {
                // Printable text, up to the next control byte. A character
                // cut off at the end of what arrived waits for its other bytes.
                var end = index
                while end < bytes.count, bytes[end] >= 0x20, bytes[end] != 0x7F { end += 1 }
                var run = bytes[index..<end]
                if end == bytes.count {
                    let cut = Self.incompleteCharacterLength(run)
                    partial = Array(run.suffix(cut))
                    run = run.dropLast(cut)
                }
                insert(String(decoding: run, as: UTF8.self))
                afterCarriageReturn = false
                index = end
            }
        }
        if action != nil {
            typeahead = Array(bytes[index...]) + partial
            partial = []
            finish()
        } else {
            render()
        }
        return action
    }

    /// Leaves the line on screen as typed and moves under it.
    func finish() {
        guard isActive else { return }
        render(final: true)
        stream.writeControl("\u{1B}[?2004l")
        stream.inputEnded()
        isActive = false
        hidden = false
    }

    private enum Key {
        case left, right, wordLeft, wordRight, home, end, up, down
        case delete, deleteWordBack, newline, pasteStart, pasteEnd, ignored
    }

    private func control(_ byte: UInt8) -> Action? {
        if pasting {
            switch byte {
            case 0x0D: insert("\n")
            case 0x0A where !afterCarriageReturn: insert("\n")
            case 0x09: insert("\t")
            default: break
            }
            afterCarriageReturn = byte == 0x0D
            return nil
        }
        afterCarriageReturn = false
        switch byte {
        case 0x0D:  // Return
            let line = String(text)
            if usesHistory, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, history.last != line {
                history.append(line)
            }
            return .submit(line)
        case 0x0A:  // Ctrl-J: a new line in the message
            insert("\n")
        case 0x03:  // Ctrl-C: clears what's typed; with nothing typed, it's the session's
            guard text.isEmpty else {
                text = []
                cursor = 0
                return nil
            }
            return .interrupt
        case 0x04:  // Ctrl-D: quits on an empty line, as at a shell
            if text.isEmpty { return .endOfInput }
            if cursor < text.count { text.remove(at: cursor) }
        case 0x7F, 0x08:  // Backspace
            if cursor > 0 {
                cursor -= 1
                text.remove(at: cursor)
            }
        case 0x01: cursor = lineStart
        case 0x05: cursor = lineEnd
        case 0x02: cursor = max(0, cursor - 1)
        case 0x06: cursor = min(text.count, cursor + 1)
        case 0x0B: text.removeSubrange(cursor..<lineEnd)
        case 0x15:
            let start = lineStart
            text.removeSubrange(start..<cursor)
            cursor = start
        case 0x17: deleteWordBack()
        default: break
        }
        return nil
    }

    private func apply(_ key: Key) -> Action? {
        if pasting {
            if key == .pasteEnd { pasting = false }
            return nil
        }
        switch key {
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(text.count, cursor + 1)
        case .wordLeft: cursor = wordStart(before: cursor)
        case .wordRight:
            while cursor < text.count, !isWord(text[cursor]) { cursor += 1 }
            while cursor < text.count, isWord(text[cursor]) { cursor += 1 }
        case .home: cursor = lineStart
        case .end: cursor = lineEnd
        case .up: moveVertically(-1)
        case .down: moveVertically(1)
        case .delete: if cursor < text.count { text.remove(at: cursor) }
        case .deleteWordBack: deleteWordBack()
        case .newline: insert("\n")
        case .pasteStart: pasting = true
        case .pasteEnd, .ignored: break
        }
        return nil
    }

    private func insert(_ string: String) {
        let characters = Array(string)
        text.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
    }

    private var lineStart: Int {
        text[..<cursor].lastIndex(of: "\n").map { $0 + 1 } ?? 0
    }

    private var lineEnd: Int {
        text[cursor...].firstIndex(of: "\n") ?? text.count
    }

    private func isWord(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isPunctuation
    }

    private func wordStart(before position: Int) -> Int {
        var start = position
        while start > 0, !isWord(text[start - 1]) { start -= 1 }
        while start > 0, isWord(text[start - 1]) { start -= 1 }
        return start
    }

    private func deleteWordBack() {
        let start = wordStart(before: cursor)
        text.removeSubrange(start..<cursor)
        cursor = start
    }

    /// Up and Down move between the lines of a message, and past its first
    /// or last line through what was sent before.
    private func moveVertically(_ step: Int) {
        let start = lineStart
        if step < 0, start > 0 {
            let previousStart = text[..<(start - 1)].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            cursor = min(previousStart + (cursor - start), start - 1)
        } else if step > 0, lineEnd < text.count {
            let nextStart = lineEnd + 1
            let nextEnd = text[nextStart...].firstIndex(of: "\n") ?? text.count
            cursor = min(nextStart + (cursor - start), nextEnd)
        } else if usesHistory {
            let target = historyIndex + step
            guard target >= 0, target <= history.count else { return }
            if historyIndex == history.count { draft = text }
            historyIndex = target
            text = target == history.count ? draft : Array(history[target])
            cursor = text.count
        }
    }

    // MARK: Escape sequences

    /// The key an escape sequence stands for and how many bytes it takes;
    /// `nil` when it hasn't fully arrived yet.
    private static func escape(in bytes: [UInt8], at start: Int) -> (Int, Key)? {
        guard start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case UInt8(ascii: "["):
            // CSI: parameters, then a final byte.
            var end = start + 2
            while end < bytes.count, (0x20...0x3F).contains(bytes[end]) { end += 1 }
            guard end < bytes.count else { return nil }
            let parameters = String(decoding: bytes[(start + 2)..<end], as: UTF8.self)
            let modified = parameters.contains(";")
            let key: Key = switch bytes[end] {
            case UInt8(ascii: "A"): .up
            case UInt8(ascii: "B"): .down
            case UInt8(ascii: "C"): modified ? .wordRight : .right
            case UInt8(ascii: "D"): modified ? .wordLeft : .left
            case UInt8(ascii: "H"): .home
            case UInt8(ascii: "F"): .end
            case UInt8(ascii: "~"):
                switch parameters {
                case "1", "7": .home
                case "4", "8": .end
                case "3": .delete
                case "200": .pasteStart
                case "201": .pasteEnd
                default: .ignored
                }
            default: .ignored
            }
            return (end - start + 1, key)
        case UInt8(ascii: "O"):
            guard start + 2 < bytes.count else { return nil }
            let key: Key = switch bytes[start + 2] {
            case UInt8(ascii: "A"): .up
            case UInt8(ascii: "B"): .down
            case UInt8(ascii: "C"): .right
            case UInt8(ascii: "D"): .left
            case UInt8(ascii: "H"): .home
            case UInt8(ascii: "F"): .end
            default: .ignored
            }
            return (3, key)
        // Option as Meta: Option-arrows send these, Option-Return a new line.
        case UInt8(ascii: "b"): return (2, .wordLeft)
        case UInt8(ascii: "f"): return (2, .wordRight)
        case 0x0D: return (2, .newline)
        case 0x7F: return (2, .deleteWordBack)
        // Escape on its own: dropped, and the key after it read as usual.
        default: return (1, .ignored)
        }
    }

    /// How many bytes at the end of `bytes` start a UTF-8 character that
    /// isn't complete yet.
    private static func incompleteCharacterLength(_ bytes: ArraySlice<UInt8>) -> Int {
        guard !bytes.isEmpty else { return 0 }
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.endIndex - back]
            guard byte & 0xC0 == 0x80 else {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return length > back ? back : 0
            }
        }
        return 0
    }

    // MARK: Drawing

    /// Erases what was drawn: from the prompt's first row down.
    private func erase() -> String {
        "\r" + (cursorRow > 0 ? "\u{1B}[\(cursorRow)A" : "") + "\u{1B}[J"
    }

    /// Draws the prompt and the text, wrapped as the terminal wraps it, then
    /// one empty row below, and puts the cursor back where it belongs. With
    /// `final`, the cursor stays on that empty row: the line is done.
    private func render(final: Bool = false) {
        guard isActive, !hidden else { return }
        let columns = stream.columns
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let indent = String(repeating: " ", count: Self.width(of: prompt.text))
        var output = erase()
        var row = 0
        var position = 0
        var cursorAt = (row: 0, column: 0)
        for (number, line) in lines.enumerated() {
            output += number == 0 ? prompt.styled : indent
            var width = Self.width(of: number == 0 ? prompt.text : indent)
            for (offset, character) in line.enumerated() {
                if position + offset == cursor { cursorAt = (row + width / columns, width % columns) }
                width += Self.width(of: character)
            }
            if position + line.count == cursor { cursorAt = (row + width / columns, width % columns) }
            output += styled(line, first: number == 0)
            // A row filled to the last column leaves the cursor waiting at
            // its end; the text's end, and the cursor, belong on the next.
            if width % columns == 0 { output += "\r\n" }
            output += "\r\n"
            row += width / columns + 1
            position += line.count + 1
        }
        if final {
            cursorRow = 0
        } else {
            output += "\u{1B}[\(row - cursorAt.row)A\r"
            if cursorAt.column > 0 { output += "\u{1B}[\(cursorAt.column)C" }
            cursorRow = cursorAt.row
        }
        stream.writeControl(output)
    }

    /// A line as drawn: tabs as spaces, and a command, at the start of the
    /// message, in bold as soon as it starts and in the accent once it's
    /// one kuri knows.
    private func styled(_ line: ArraySlice<Character>, first: Bool) -> String {
        var drawn = String(line).replacingOccurrences(of: "\t", with: String(repeating: " ", count: Self.tabWidth))
        if first, styleCommands, drawn.hasPrefix("/") {
            let name = String(drawn.prefix { $0 != " " })
            let rest = String(drawn.dropFirst(name.count))
            drawn = commands.contains(name)
                ? stream.style(name, .bold, .accent) + rest
                : stream.style(name, .bold) + rest
        }
        return drawn
    }

    static func width(of string: String) -> Int {
        string.reduce(0) { $0 + width(of: $1) }
    }

    /// Columns a character takes in the terminal: two for wide and emoji
    /// characters, none for a combining mark.
    static func width(of character: Character) -> Int {
        if character == "\t" { return tabWidth }
        var width = 0
        for scalar in character.unicodeScalars {
            // U+FE0F asks for the emoji presentation, drawn two columns wide.
            if scalar.value == 0xFE0F { return 2 }
            width = max(width, Int(wcwidth(wchar_t(scalar.value))))
        }
        return width
    }
}
