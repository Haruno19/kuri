import Darwin
import Foundation
import Synchronization

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
    private(set) var trailingNewlines = 2

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

    /// Writes cursor movements and other control sequences, which leave
    /// the count of trailing newlines as it was.
    func writeControl(_ text: String) {
        let kept = trailingNewlines
        write(text)
        trailingNewlines = kept
    }

    /// Something drawn and then erased (the prompt, hidden to write output
    /// above it) left the output ending as it did before.
    func restoreTrailingNewlines(_ count: Int) {
        trailingNewlines = count
    }

    /// The terminal's size; 80 by 24 when it can't tell.
    var size: (columns: Int, rows: Int) {
        var size = winsize()
        guard isTerminal, withUnsafeMutablePointer(to: &size, { ioctl(fd, TIOCGWINSZ, $0) }) == 0,
              size.ws_col > 0, size.ws_row > 0
        else { return (80, 24) }
        return (Int(size.ws_col), Int(size.ws_row))
    }

    var columns: Int { size.columns }

    func line(_ text: String = "") {
        endLine()
        write(text + "\n")
    }

    func style(_ text: String, _ styles: Style...) -> String {
        guard styled, !styles.isEmpty, !text.isEmpty else { return text }
        return "\u{1B}[\(styles.map(\.code).joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    /// Scrolls what's on screen up into the scrollback and starts again at
    /// the top: like `clear`, without throwing the terminal's history away.
    func clearScreen() {
        guard isTerminal else { return }
        let rows = size.rows
        write("\u{1B}[\(rows);1H" + String(repeating: "\n", count: rows) + "\u{1B}[H")
        trailingNewlines = 2
    }

    /// Something else wrote to the terminal (a `/shell` command): assume it
    /// ended its line, as commands do.
    func othersWrote() {
        trailingNewlines = 1
    }
}

enum Style {
    case bold, dim, italic, red, green, yellow
    /// Kuri's chestnut, for commands.
    case accent
    /// Its lighter tone, as the inspector's context bar uses for messages.
    case accentLight

    var code: String {
        switch self {
        case .bold: "1"
        case .dim: "2"
        case .italic: "3"
        case .red: "31"
        case .green: "32"
        case .yellow: "33"
        case .accent: Self.accentCode
        case .accentLight: Self.accentLightCode
        }
    }

    /// Between the app's light and dark accents (#A4693D, #C08452), since a
    /// terminal's background may be either; terminals without 24-bit colour
    /// get the nearest of the 256 (#AF875F).
    static let accentCode = color(red: 0xB2, green: 0x77, blue: 0x48, else: 137)
    /// Between #C18A5B and #D6A06F, the same way; else #D7875F.
    static let accentLightCode = color(red: 0xCB, green: 0x95, blue: 0x65, else: 173)

    private static let truecolor: Bool = {
        let colorterm = ProcessInfo.processInfo.environment["COLORTERM"] ?? ""
        return colorterm == "truecolor" || colorterm == "24bit"
    }()

    private static func color(red: Int, green: Int, blue: Int, else fallback: Int) -> String {
        truecolor ? "38;2;\(red);\(green);\(blue)" : "38;5;\(fallback)"
    }
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
    /// Space around the header: lines above it, columns before it.
    static let topMargin = 1
    static let leftMargin = 2
    static let gap = "   "

    /// The header as text to write, margins included.
    static func text(_ lines: [String], on stream: Stream) -> String {
        let rows = max(hero.count, lines.count)
        let width = hero.map(\.count).max() ?? 0
        let margin = String(repeating: " ", count: leftMargin)
        let body = (0..<rows).map { row in
            let art = row < hero.count ? hero[row] : ""
            let padded = art.padding(toLength: width, withPad: " ", startingAt: 0)
            let words = row < lines.count ? lines[row] : ""
            return margin + stream.style(padded, .dim) + gap + words
        }
        return String(repeating: "\n", count: topMargin) + body.joined(separator: "\n") + "\n"
    }
}

/// What's typed, read on a thread of their own: a read blocks until a key
/// or line arrives, and the main actor has events to handle meanwhile.
/// Lines, as the terminal edits and echoes them, while kuri isn't waiting
/// for input; keys, for the line editor, while it is (the terminal in raw
/// mode); or nothing, while a `/shell` command has the terminal's input to
/// itself instead of racing this thread for every key.
nonisolated final class InputReader: Sendable {
    enum Mode: Sendable {
        case lines, keys, paused
    }

    enum Typed: Sendable {
        case line(String)
        case keys([UInt8])
    }

    /// How often a paused or idle reader looks again.
    static let pollInterval: Int32 = 50

    let typed: AsyncStream<Typed>
    /// The mode, and a count of switches, so a read never mixes two modes.
    private let state = Mutex((mode: Mode.lines, switches: 0))

    init() {
        let (typed, continuation) = AsyncStream.makeStream(of: Typed.self)
        self.typed = typed
        Thread { [self] in read(into: continuation) }.start()
    }

    /// Switches mode, running `apply` (the terminal's settings) while no
    /// read is under way: what's read next is read in the new mode.
    func switchTo(_ mode: Mode, _ apply: () -> Void = {}) {
        state.withLock { state in
            guard state.mode != mode else { return }
            state.mode = mode
            state.switches += 1
            apply()
        }
    }

    private func read(into continuation: AsyncStream<Typed>.Continuation) {
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let (mode, switches) = state.withLock { $0 }
            if mode == .paused {
                usleep(useconds_t(Self.pollInterval) * 1000)
                continue
            }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollInterval)
            if ready < 0, errno != EINTR { break }
            guard ready > 0 else { continue }
            // Read under the lock, and only if the mode hasn't changed since
            // the poll: a line read now can't block on a terminal that was
            // meanwhile put back into line mode.
            let count = state.withLock { state in
                state.switches == switches
                    ? buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    : nil
            }
            guard let count else { continue }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending += buffer[..<count]
            if mode == .keys {
                continuation.yield(.keys(pending))
                pending = []
                continue
            }
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                continuation.yield(.line(String(decoding: pending[..<end], as: UTF8.self)))
                pending.removeSubrange(...end)
            }
        }
        if !pending.isEmpty { continuation.yield(.line(String(decoding: pending, as: UTF8.self))) }
        continuation.finish()
    }
}

/// The terminal's input settings: as found, or raw for the line editor.
nonisolated enum TerminalInput {
    /// As kuri found them; read before anything changes them.
    static let original: termios? = {
        var settings = termios()
        return tcgetattr(STDIN_FILENO, &settings) == 0 ? settings : nil
    }()

    /// Every key as it's typed, unechoed: Ctrl-C and Ctrl-D become keys
    /// like the others, and Return stays a carriage return, apart from
    /// Ctrl-J's newline.
    static func keys() {
        guard var settings = original else { return }
        settings.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        settings.c_iflag &= ~tcflag_t(ICRNL | IXON)
        withUnsafeMutablePointer(to: &settings.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { characters in
                characters[Int(VMIN)] = 1
                characters[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &settings)
    }

    static func lines() {
        guard var settings = original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &settings)
    }
}

/// A command run on the terminal itself, as a shell runs a foreground job.
/// Foundation's `Process` won't do: it puts the child in a process group of
/// its own, which the terminal treats as a background job, so the
/// command's first read of a key stops it (SIGTTIN) and Ctrl-C never
/// reaches it.
nonisolated enum ForegroundCommand {
    enum Ending: Equatable {
        case exited(Int32)
        case signalled(Int32)
    }

    /// Runs `arguments` (the first is the program) in `directory`, sharing
    /// this process's group, terminal and environment. `nil` if it couldn't
    /// start.
    static func run(_ arguments: [String], in directory: String) async -> Ending? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // kuri ignores SIGINT, SIGTERM and SIGHUP to handle them itself, and
        // an ignored signal stays ignored across exec: give them back their
        // defaults, and an empty mask, so Ctrl-C stops the command.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir(&actions, directory)

        let argv = arguments.map { strdup($0) } + [nil]
        defer { for argument in argv { free(argument) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environ) == 0 else {
            return nil
        }
        let child = pid
        return await withCheckedContinuation { continuation in
            Thread {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
                // The wait status: the low 7 bits are the signal that ended it, if any.
                let signal = status & 0x7F
                continuation.resume(returning: signal == 0 ? .exited((status >> 8) & 0xFF) : .signalled(signal))
            }.start()
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
