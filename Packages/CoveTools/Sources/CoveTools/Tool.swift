import Foundation
@_exported import CoveModels

/// Hints used by the approval gate (mirrors MCP tool annotations).
public struct ToolAnnotations: Codable, Sendable, Hashable {
    /// The tool never modifies anything (MCP `readOnlyHint`).
    public var readOnly: Bool
    /// The tool may delete or overwrite data (MCP `destructiveHint`).
    public var destructive: Bool
    /// The tool spends money or sends something on the user's behalf.
    public var spendsOrSends: Bool
    /// The tool needs the network; it is marked unavailable while offline.
    public var requiresNetwork: Bool

    public init(readOnly: Bool, destructive: Bool = false, spendsOrSends: Bool = false, requiresNetwork: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.spendsOrSends = spendsOrSends
        self.requiresNetwork = requiresNetwork
    }

    /// Whether `askOnWrite` should prompt for this tool.
    public var isWrite: Bool { !readOnly || destructive || spendsOrSends }
}

public struct ToolContext: Sendable {
    public var chatID: String
    public var isOnline: Bool
    public var attachmentSink: (any AttachmentSink)?

    public init(chatID: String, isOnline: Bool = true, attachmentSink: (any AttachmentSink)? = nil) {
        self.chatID = chatID
        self.isOnline = isOnline
        self.attachmentSink = attachmentSink
    }
}

public enum ToolError: Error, Sendable, Equatable, LocalizedError {
    case invalidArguments(String)
    case notConfigured(String)
    case unavailableOffline
    case denied
    case failed(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): "Invalid arguments: \(detail)"
        case .notConfigured(let detail): "Not configured: \(detail)"
        case .unavailableOffline: "This tool needs a network connection and the Mac is offline."
        case .denied: "The user declined this tool call."
        case .failed(let detail): detail
        case .unknownTool(let name): "Unknown tool: \(name)"
        }
    }
}

/// Built-in tools and MCP tools implement the same protocol, so the engine
/// treats them identically (§20).
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    var annotations: ToolAnnotations { get }
    /// Runs the tool. Throwing is reported back to the model as an error
    /// result; it never aborts the conversation.
    func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult
}

extension Tool {
    public var name: String { spec.name }
}
