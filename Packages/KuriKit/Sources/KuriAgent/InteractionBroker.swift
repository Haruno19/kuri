import Foundation
import KuriTools

/// Parks tool calls that need the user until someone answers.
///
/// Tools call `clarify` / `approve` and suspend; the broker publishes an
/// `InputRequest`, and `respond` resumes the waiting call. Cancelling the
/// turn cancels the wait.
actor InteractionBroker: UserInteraction {
    private var pending: [UUID: CheckedContinuation<InputResponse, any Error>] = [:]
    private var requests: [UUID: InputRequest] = [:]
    private let emit: @Sendable (EngineEvent) -> Void

    init(emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.emit = emit
    }

    var openRequests: [InputRequest] { Array(requests.values) }

    func clarify(_ request: ClarifyRequest) async throws -> [String: String] {
        guard case .answers(let answers) = try await ask(.clarify(request)) else { return [:] }
        return answers
    }

    func approve(_ request: ApprovalRequest) async throws -> Bool {
        guard case .approved(let approved) = try await ask(.approval(request)) else { return false }
        return approved
    }

    func respond(to id: UUID, with response: InputResponse) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        requests[id] = nil
        emit(.inputResolved(requestID: id))
        continuation.resume(returning: response)
    }

    private func ask(_ kind: InputRequest.Kind) async throws -> InputResponse {
        let request = InputRequest(id: UUID(), kind: kind)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                requests[request.id] = request
                emit(.inputRequested(request))
            }
        } onCancel: {
            Task { await self.cancel(request.id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        requests[id] = nil
        emit(.inputResolved(requestID: id))
        continuation.resume(throwing: CancellationError())
    }
}
