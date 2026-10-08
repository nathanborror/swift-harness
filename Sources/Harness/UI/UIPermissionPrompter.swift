import Foundation
import Observation

/// A prompter that turns an `ask` into observable state for a view to render.
///
/// The gate awaits `confirm`, which parks the request on `pending`; the view
/// shows it and calls `respond`. A wait for a person needs a finite end, so a
/// request that is not answered within the timeout is denied.
@MainActor
@Observable
public final class UIPermissionPrompter: PermissionPrompter {
    public struct Request: Identifiable, Sendable {
        public let id: UUID
        public let invocation: ToolInvocation
        public let askedAt: Date
    }

    public private(set) var pending: Request?
    public private(set) var queued: Int = 0
    public let timeout: Duration

    private var continuation: CheckedContinuation<PermissionResponse, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(timeout: Duration = .seconds(300)) {
        self.timeout = timeout
    }

    public nonisolated func confirm(_ invocation: ToolInvocation) async -> PermissionResponse {
        await ask(invocation)
    }

    private func ask(_ invocation: ToolInvocation) async -> PermissionResponse {
        // Serialize asks so a view shows one at a time.
        while pending != nil {
            queued += 1
            await withCheckedContinuation { waiters.append($0) }
            queued -= 1
        }
        let request = Request(id: UUID(), invocation: invocation, askedAt: Date())
        pending = request
        let timeout = self.timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(request.id, with: .deny)
        }
        let response = await withCheckedContinuation { continuation = $0 }
        timer.cancel()
        return response
    }

    /// Answers the pending request.
    public func respond(_ response: PermissionResponse) {
        guard let pending else { return }
        finish(pending.id, with: response)
    }

    private func finish(_ id: UUID, with response: PermissionResponse) {
        guard pending?.id == id, let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: response)
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
