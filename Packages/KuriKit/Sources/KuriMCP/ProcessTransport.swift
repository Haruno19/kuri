import Foundation
import Logging
import MCP

/// MCP over the stdin/stdout of a child process that this transport owns.
///
/// The SDK's `StdioTransport` takes file descriptors and polls them every
/// 10 ms while idle; this one launches the server itself and is driven by
/// readability callbacks, so an idle server costs nothing. The stream of
/// messages ends with an error when the server closes its stdout, which
/// also stops the SDK client's receive loop.
actor ProcessTransport: Transport {
    nonisolated let logger = Logger(label: "kuri.mcp.process", factory: { _ in SwiftLogNoOpLogHandler() })

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let messages: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let onStderr: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    struct Closed: LocalizedError {
        var errorDescription: String? { "The server closed its output." }
    }

    /// - Parameters:
    ///   - command: An absolute path, or a name looked up in `environment["PATH"]`.
    ///   - onStderr: Each line the server writes to stderr (its log).
    ///   - onExit: The exit status, once the process ends.
    init(command: String, arguments: [String], environment: [String: String],
         onStderr: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment
        (messages, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        self.onStderr = onStderr
        self.onExit = onExit
    }

    func connect() async throws {
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Writing to a server that died must fail with EPIPE, not kill Kuri with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let continuation = continuation
        let lines = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish(throwing: Closed())
                return
            }
            for line in lines.append(data) where !line.isEmpty {
                continuation.yield(line)
            }
        }

        let onStderr = onStderr
        let logLines = LineSplitter()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in logLines.append(data) {
                onStderr(String(decoding: line, as: UTF8.self))
            }
        }

        let onExit = onExit
        process.terminationHandler = { process in
            onExit(process.terminationStatus)
        }

        try process.run()
    }

    func disconnect() async {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        var message = data
        message.append(UInt8(ascii: "\n"))
        try stdin.fileHandleForWriting.write(contentsOf: message)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }
}

/// Splits a byte stream into newline-terminated lines.
/// Only used from one readability handler, which runs serially.
private final class LineSplitter: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[pending.startIndex..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            lines.append(Data(line))
            pending = pending[pending.index(after: newline)...]
        }
        if pending.isEmpty { pending = Data() }
        return lines
    }
}
