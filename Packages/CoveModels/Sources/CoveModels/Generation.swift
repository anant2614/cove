import Foundation

/// A JSON-Schema tool definition offered to the model.
public struct ToolSpec: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum ReasoningEffort: String, Codable, Sendable, Hashable, CaseIterable {
    case minimal, low, medium, high
}

public struct GenerationParameters: Codable, Sendable, Hashable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public var topK: Int?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var reasoningEffort: ReasoningEffort?
    public var stop: [String]?

    public init(
        temperature: Double? = nil, maxTokens: Int? = nil, topP: Double? = nil, topK: Int? = nil,
        frequencyPenalty: Double? = nil, presencePenalty: Double? = nil,
        reasoningEffort: ReasoningEffort? = nil, stop: [String]? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.topK = topK
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.reasoningEffort = reasoningEffort
        self.stop = stop
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var parameters: GenerationParameters
    /// The context window (in tokens) the request was fitted to. Servers that
    /// size their context per request (Ollama) must be given this value, or
    /// they silently drop the start of the prompt.
    public var contextWindow: Int?

    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [], parameters: GenerationParameters = .init(),
                contextWindow: Int? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.parameters = parameters
        self.contextWindow = contextWindow
    }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int?
    public var cachedInputTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int? = nil, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningTokens: sumOptional(lhs.reasoningTokens, rhs.reasoningTokens),
            cachedInputTokens: sumOptional(lhs.cachedInputTokens, rhs.cachedInputTokens)
        )
    }

    private static func sumOptional(_ a: Int?, _ b: Int?) -> Int? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }
}

public enum FinishReason: Sendable, Hashable, Codable {
    case stop
    case length
    case toolCalls
    case contentFilter
    case cancelled
    case error
    case other(String)

    public var rawValue: String {
        switch self {
        case .stop: "stop"
        case .length: "length"
        case .toolCalls: "tool_calls"
        case .contentFilter: "content_filter"
        case .cancelled: "cancelled"
        case .error: "error"
        case .other(let value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "stop", "end_turn", "STOP", "stop_sequence": self = .stop
        case "length", "max_tokens", "MAX_TOKENS": self = .length
        case "tool_calls", "tool_use", "function_call": self = .toolCalls
        case "content_filter", "SAFETY", "refusal": self = .contentFilter
        case "cancelled": self = .cancelled
        case "error": self = .error
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One event in a streamed model response. Providers accumulate partial tool
/// call deltas and emit each `toolCall` once it is complete.
public enum ChatEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
    case finished(FinishReason)
}
