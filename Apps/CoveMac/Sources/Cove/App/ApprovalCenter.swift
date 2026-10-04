import CoveCore
import Foundation
import Observation

/// Presents tool-approval prompts (§20 "Ask before acting") inline in the
/// chat that requested them and suspends the engine until the user decides.
@MainActor
@Observable
final class ApprovalCenter: ApprovalRequester {
    struct Pending: Identifiable {
        let request: ApprovalRequest
        let continuation: CheckedContinuation<ApprovalDecision, Never>
        var id: String { request.id }
    }

    private(set) var pending: [Pending] = []

    nonisolated func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.pending.append(Pending(request: request, continuation: continuation))
            }
        }
    }

    func pending(for chatID: String) -> [Pending] {
        pending.filter { $0.request.chatID == chatID }
    }

    func resolve(_ id: String, _ decision: ApprovalDecision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        item.continuation.resume(returning: decision)
    }

    /// Denies anything still waiting for a chat (e.g. it was deleted or stopped).
    func forget(chatID: String) async {
        for item in pending where item.request.chatID == chatID {
            resolve(item.id, .deny)
        }
    }
}
