import Foundation

/// Per-tool approval rule (§20, T4). `always` = always ask the user.
public enum ApprovalPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    case always
    case askOnWrite
    case never

    public var label: String {
        switch self {
        case .always: "Always ask"
        case .askOnWrite: "Ask for writes"
        case .never: "Never ask"
        }
    }
}

public struct ApprovalRequest: Sendable, Hashable, Identifiable {
    public var id: String { call.id }
    public var chatID: String
    public var call: ToolCall
    public var toolName: String
    public var toolDescription: String
    public var annotations: ToolAnnotations

    public init(chatID: String, call: ToolCall, toolName: String, toolDescription: String, annotations: ToolAnnotations) {
        self.chatID = chatID
        self.call = call
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.annotations = annotations
    }
}

public enum ApprovalDecision: String, Sendable, Hashable {
    case allowOnce
    /// Remember the approval for this tool for the rest of the chat.
    case allowForChat
    case deny
}

/// Presents approval prompts to the user (implemented by the UI).
public protocol ApprovalRequester: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision
}
