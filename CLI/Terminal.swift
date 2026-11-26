import Darwin
import Foundation

/// stdout or stderr. Styles reach only a terminal, and never with
/// `NO_COLOR` set (no-color.org), so piped output stays plain text.
final class Stream {
    static let out = Stream(fd: STDOUT_FILENO)
    static let err = Stream(fd: STDERR_FILENO)

    let fd: Int32
    let isTerminal: Bool
    let styled: Bool
    /// How many newlines the output ends with, so blocks can be kept one
    /// blank line apart without counting what came before. Nothing written
    /// yet counts as a blank line: no block starts with an empty one.
    private var trailingNewlines = 2

    private init(fd: Int32) {
        self.fd = fd
        isTerminal = isatty(fd) == 1
        styled = isTerminal && (ProcessInfo.processInfo.environment["NO_COLOR"] ?? "").isEmpty
    }

    func write(_ text: String) {
        guard !text.isEmpty else { return }
        var text = text
        text.withUTF8 { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        let newlines = text.reversed().prefix(while: \.isNewline).count
        trailingNewlines = newlines == text.count ? trailingNewlines + newlines : newlines
    }

    /// Ends the current line, if one is open.
    func endLine() {
        if trailingNewlines == 0 { write("\n") }
    }

    /// Leaves exactly one empty line before what comes next.
    func blankLine() {
        if trailingNewlines < 2 { write(String(repeating: "\n", count: 2 - trailingNewlines)) }
    }

    /// The terminal echoed the Return that ended a typed line, so the
    /// cursor is at the start of a line we didn't write.
    func inputEnded() {
        trailingNewlines = 1
    }

    /// The terminal echoed a control key (`^C`) after the cursor.
    func controlEchoed() {
        trailingNewlines = 0
    }

    func line(_ text: String = "") {
        endLine()
        write(text + "\n")
    }

    func style(_ text: String, _ styles: Style...) -> String {
        guard styled, !styles.isEmpty, !text.isEmpty else { return text }
        return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m\(text)\u{1B}[0m"
    }
}

enum Style: String {
    case bold = "1", dim = "2", italic = "3", red = "31", green = "32", yellow = "33"
}

/// The session's opening lines. The left column belongs to a hero, a small
/// drawing that says Kuri at a glance (a chestnut shell, one day); until
/// it's drawn, a plain frame holds its place, so the text beside it won't
/// move when it lands.
enum Header {
    static let hero = [
        "╭───╮",
        "│   │",
        "╰───╯",
    ]
    static let gap = "   "

    static func lines(_ text: [String], on stream: Stream) -> [String] {
        let rows = max(hero.count, text.count)
        let width = hero.map(\.count).max() ?? 0
        return (0..<rows).map { row in
            let art = row < hero.count ? hero[row] : ""
            let padded = art.padding(toLength: width, withPad: " ", startingAt: 0)
            let words = row < text.count ? text[row] : ""
            return stream.style(padded, .dim) + gap + words
        }
    }
}

/// Lines of a file, read on a thread of their own: a read blocks until a
/// line is typed, and the main actor has events to handle meanwhile.
enum LineReader {
    nonisolated static func stdin() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.start()
        }
    }
}

/// The controlling terminal, for questions when stdin and stdout are
/// taken: `kuri -p` asks its approvals here (decision 0028).
enum TTY {
    nonisolated static var isAvailable: Bool {
        let fd = open("/dev/tty", O_RDWR)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Writes `prompt` to the terminal and waits for a line; `nil` without
    /// a terminal, or at end of file.
    nonisolated static func ask(_ prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                guard let file = fopen("/dev/tty", "r+") else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { fclose(file) }
                fputs(prompt, file)
                fflush(file)
                var buffer: UnsafeMutablePointer<CChar>?
                var capacity = 0
                defer { free(buffer) }
                guard getline(&buffer, &capacity, file) > 0, let buffer else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(cString: buffer).trimmingCharacters(in: .newlines))
            }
            thread.start()
        }
    }
}

/// Signals as main-actor callbacks. Ignoring a signal's default action and
/// watching it with a dispatch source is what lets Ctrl-C stop a turn
/// instead of killing the process mid-write.
final class Signals {
    private var sources: [DispatchSourceSignal] = []

    func on(_ number: Int32, _ handler: @escaping @MainActor @Sendable () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        sources.append(source)
    }
}
