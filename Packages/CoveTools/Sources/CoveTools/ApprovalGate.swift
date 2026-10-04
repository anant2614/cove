import Foundation

/// Decides whether a tool call may run, prompting the user when the tool's
/// policy requires it (§20, T4).
///
/// `.allowForChat` answers are remembered per (chat, tool) so the user is not
/// asked again for that tool in the same chat.
public actor ApprovalGate {
    private struct ChatTool: Hashable {
        var chatID: String
        var toolName: String
    }

    private let requester: any ApprovalRequester
    private var allowedForChat: Set<ChatTool> = []

    /// Creates a gate that asks `requester` (normally the UI) when needed.
    public init(requester: any ApprovalRequester) {
        self.requester = requester
    }

    /// Returns `true` when `call` may run.
    ///
    /// - `.never`: always allowed.
    /// - `.askOnWrite`: allowed without asking for read-only tools; otherwise asks.
    /// - `.always`: asks.
    ///
    /// A prior `.allowForChat` for the same tool and chat skips the prompt.
    public func authorize(call: ToolCall, tool: any Tool, policy: ApprovalPolicy, chatID: String) async -> Bool {
        switch policy {
        case .never:
            return true
        case .askOnWrite where !tool.annotations.isWrite:
            return true
        case .askOnWrite, .always:
            break
        }

        let key = ChatTool(chatID: chatID, toolName: tool.name)
        if allowedForChat.contains(key) { return true }

        let request = ApprovalRequest(
            chatID: chatID,
            call: call,
            toolName: tool.name,
            toolDescription: tool.spec.description,
            annotations: tool.annotations
        )
        // The actor may be re-entered while awaiting the user; that is fine
        // since the only state change below is an idempotent insert.
        switch await requester.requestApproval(request) {
        case .allowOnce:
            return true
        case .allowForChat:
            allowedForChat.insert(key)
            return true
        case .deny:
            return false
        }
    }

    /// Whether `toolName` has been approved for the rest of `chatID`.
    public func isAllowedForChat(toolName: String, chatID: String) -> Bool {
        allowedForChat.contains(ChatTool(chatID: chatID, toolName: toolName))
    }

    /// Drops remembered approvals for `chatID` (e.g. when the chat is deleted).
    public func forgetChat(_ chatID: String) {
        allowedForChat = allowedForChat.filter { $0.chatID != chatID }
    }
}

/// An `ApprovalRequester` that answers every request with a fixed decision,
/// for tests and headless use.
public struct AutoApprover: ApprovalRequester {
    /// The decision returned for every request.
    public let decision: ApprovalDecision

    public init(_ decision: ApprovalDecision = .allowOnce) {
        self.decision = decision
    }

    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        decision
    }
}
