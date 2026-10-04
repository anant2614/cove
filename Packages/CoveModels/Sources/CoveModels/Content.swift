import Foundation

public enum Role: String, Codable, Sendable, Hashable, CaseIterable {
    case system
    case user
    case assistant
    /// The result of a tool call, sent back to the model.
    case tool
}

/// An image in a message. Persisted messages reference images by
/// `attachmentID`; `data` is filled in ("hydrated") only when a request is
/// built so the database never stores large base64 blobs.
public struct ImageContent: Codable, Sendable, Hashable {
    public var mime: String
    public var data: Data?
    public var attachmentID: String?

    public init(mime: String, data: Data? = nil, attachmentID: String? = nil) {
        self.mime = mime
        self.data = data
        self.attachmentID = attachmentID
    }

    public var base64: String? { data?.base64EncodedString() }
    public var dataURL: String? { base64.map { "data:\(mime);base64,\($0)" } }
}

/// A non-image file whose text has been extracted (text, code, PDF text).
public struct FileContent: Codable, Sendable, Hashable {
    public var name: String
    public var mime: String
    public var text: String
    public var attachmentID: String?

    public init(name: String, mime: String, text: String, attachmentID: String? = nil) {
        self.name = name
        self.mime = mime
        self.text = text
        self.attachmentID = attachmentID
    }
}

/// A tool invocation requested by the model.
public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Raw JSON arguments, exactly as the model produced them.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public func parsedArguments() throws -> JSONValue { try JSONValue.parse(arguments) }
}

/// The outcome of running a tool, sent back to the model.
public struct ToolResult: Codable, Sendable, Hashable {
    public var callID: String
    public var name: String
    public var text: String
    public var images: [ImageContent]
    public var isError: Bool
    /// Structured extras for the UI (e.g. search sources). Not sent to the model.
    public var metadata: JSONValue?

    public init(callID: String, name: String, text: String, images: [ImageContent] = [], isError: Bool = false, metadata: JSONValue? = nil) {
        self.callID = callID
        self.name = name
        self.text = text
        self.images = images
        self.isError = isError
        self.metadata = metadata
    }
}

public enum ContentPart: Codable, Sendable, Hashable {
    case text(String)
    case image(ImageContent)
    case file(FileContent)
    case reasoning(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)

    private enum CodingKeys: String, CodingKey { case type, text, image, file, toolCall, toolResult }
    private enum Kind: String, Codable { case text, image, file, reasoning, toolCall = "tool_call", toolResult = "tool_result" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .reasoning: self = .reasoning(try c.decode(String.self, forKey: .text))
        case .image: self = .image(try c.decode(ImageContent.self, forKey: .image))
        case .file: self = .file(try c.decode(FileContent.self, forKey: .file))
        case .toolCall: self = .toolCall(try c.decode(ToolCall.self, forKey: .toolCall))
        case .toolResult: self = .toolResult(try c.decode(ToolResult.self, forKey: .toolResult))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode(Kind.text, forKey: .type); try c.encode(text, forKey: .text)
        case .reasoning(let text):
            try c.encode(Kind.reasoning, forKey: .type); try c.encode(text, forKey: .text)
        case .image(let image):
            try c.encode(Kind.image, forKey: .type); try c.encode(image, forKey: .image)
        case .file(let file):
            try c.encode(Kind.file, forKey: .type); try c.encode(file, forKey: .file)
        case .toolCall(let call):
            try c.encode(Kind.toolCall, forKey: .type); try c.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try c.encode(Kind.toolResult, forKey: .type); try c.encode(result, forKey: .toolResult)
        }
    }
}

/// A message as sent to a provider: a role plus content parts.
public struct ChatMessage: Codable, Sendable, Hashable {
    public var role: Role
    public var content: [ContentPart]

    public init(role: Role, content: [ContentPart]) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: [.text(text)]) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: [.text(text)]) }

    /// Concatenated plain text of all `.text` parts.
    public var text: String { content.plainText }
    public var toolCalls: [ToolCall] { content.compactMap { if case .toolCall(let c) = $0 { c } else { nil } } }
    public var toolResults: [ToolResult] { content.compactMap { if case .toolResult(let r) = $0 { r } else { nil } } }
    public var images: [ImageContent] { content.compactMap { if case .image(let i) = $0 { i } else { nil } } }
    public var files: [FileContent] { content.compactMap { if case .file(let f) = $0 { f } else { nil } } }
}

extension Array where Element == ContentPart {
    public var plainText: String {
        compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    public var reasoningText: String {
        compactMap { if case .reasoning(let t) = $0 { t } else { nil } }.joined()
    }

    /// Text used for full-text search: message text, file names and tool output.
    public var searchableText: String {
        compactMap { part -> String? in
            switch part {
            case .text(let t): t
            case .file(let f): f.name
            case .toolResult(let r): r.isError ? nil : String(r.text.prefix(2_000))
            default: nil
            }
        }.joined(separator: "\n")
    }
}
