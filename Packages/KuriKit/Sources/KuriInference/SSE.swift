import Foundation
import KuriCore

/// One server-sent event.
public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
}

/// Incremental parser for `text/event-stream`, fed one byte at a time.
///
/// Works on raw bytes rather than `AsyncBytes.lines`, because the blank
/// lines that end an event are significant and line sequences drop them.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// Returns an event when `byte` completes one.
    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        return process(String(decoding: line, as: UTF8.self))
    }

    /// Flushes an event left unterminated when the stream ends.
    public mutating func finish() -> SSEEvent? {
        if !line.isEmpty, let event = feed(UInt8(ascii: "\n")) { return event }
        return process("")
    }

    private mutating func process(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventName = nil
                return nil
            }
            let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll()
            eventName = nil
            return event
        }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        default: break  // id, retry: not needed
        }
        return nil
    }
}

enum HTTP {
    /// POSTs `body` and streams back the server-sent events.
    static func eventStream(
        session: URLSession, url: URL, headers: [String: String], body: JSONValue
    ) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Whether the server answered: a failure after that is the
                // provider going away mid-reply.
                var started = false
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    // How long the stream may stay silent. Local servers queue
                    // requests and can take minutes over a long prompt before
                    // the first byte; a stalled turn can always be cancelled.
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                    // Sorted keys: the same history always encodes to the same
                    // bytes, which keeps providers' prompt caches warm.
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    request.httpBody = try encoder.encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try await check(response, bytes: bytes)
                    started = true

                    var parser = SSEParser()
                    for try await byte in bytes {
                        if let event = parser.feed(byte) { continuation.yield(event) }
                    }
                    if let event = parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: translate(error, url: url, midway: started))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func getJSON(session: URLSession, url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw translate(error, url: url, midway: false)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KuriError.http(status: http.statusCode, body: describe(Array(data.prefix(4000))))
        }
        return data
    }

    /// The message inside a JSON error body (`{"error": {"message": …}}`,
    /// the shape OpenAI- and Anthropic-style servers share), or the raw text.
    static func describe(_ body: [UInt8]) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: Data(body)))?.error?.message { return message }
        return String(decoding: body.prefix(2000), as: UTF8.self)
    }

    /// Connection failures come from URLSession worded for networks ("The
    /// network connection was lost"), though the provider is often a local
    /// server; say which provider stopped answering instead.
    static func translate(_ error: any Error, url: URL, midway: Bool) -> any Error {
        guard let error = error as? URLError else { return error }
        let endpoint = url.host().map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
        switch error.code {
        case .timedOut:
            return KuriError.providerTimedOut(endpoint: endpoint)
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .resourceUnavailable, .badServerResponse, .secureConnectionFailed:
            return KuriError.providerUnreachable(endpoint: endpoint, midway: midway)
        default:
            return error
        }
    }

    private static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        var body: [UInt8] = []
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 4000 { break }
        }
        throw KuriError.http(status: http.statusCode, body: describe(body))
    }
}
