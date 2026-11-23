import Foundation
import KuriCore
import Testing
@testable import KuriInference

/// Fails every request: `refused.test` before any response, `dropped.test`
/// after the headers and part of a stream, as when a local server is stopped.
final class FailingServerProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        ["refused.test", "dropped.test", "silent.test"].contains(request.url?.host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch request.url?.host {
        case "dropped.test":
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                                  headerFields: ["Content-Type": "text/event-stream"])!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"partial\":true}\n\n".utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case "silent.test":
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }
    override func stopLoading() {}
}

@Suite struct UnreachableProviderTests {
    private func failure(host: String) async -> (any Error)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingServerProtocol.self]
        let stream = HTTP.eventStream(session: URLSession(configuration: configuration),
                                      url: URL(string: "http://\(host):11434/v1/responses")!, headers: [:], body: .object([:]))
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    @Test func aRefusedConnectionNamesTheProvider() async throws {
        let error = try #require(await failure(host: "refused.test") as? KuriError)
        guard case .providerUnreachable(let endpoint, let midway) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(endpoint == "refused.test:11434")
        #expect(!midway)
        #expect(!error.localizedDescription.localizedCaseInsensitiveContains("network"))
    }

    @Test func aProviderStoppedMidReplySaysSo() async throws {
        let error = try #require(await failure(host: "dropped.test") as? KuriError)
        guard case .providerUnreachable(_, let midway) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(midway)
        #expect(error.localizedDescription.contains("partway through the reply"))
    }

    @Test func aSilentProviderTimesOut() async throws {
        let error = try #require(await failure(host: "silent.test") as? KuriError)
        guard case .providerTimedOut(let endpoint) = error else {
            Issue.record("unexpected \(error)")
            return
        }
        #expect(endpoint == "silent.test:11434")
    }
}
