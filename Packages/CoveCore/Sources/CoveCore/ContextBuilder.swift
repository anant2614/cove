import Foundation

/// What the context builder included, for the message context inspector.
public struct ContextReport: Sendable, Hashable {
    public var includedMessageIDs: [String]
    public var droppedMessageCount: Int
    public var estimatedInputTokens: Int
    public var budgetTokens: Int
}

/// Decides what fits in the model's context window (§16):
/// 1. system prompt (chat/agent instructions + extra blocks such as notices),
/// 2. chat history from newest to oldest, whole turns at a time, until the
///    token budget runs out. The newest turn is always included; if it alone
///    is over budget, its tool results are shortened to fit.
public struct ContextBuilder: Sendable {
    public struct Input: Sendable {
        public var model: String
        public var systemPrompt: String?
        public var extraSystemBlocks: [String]
        /// Root → leaf path of the branch being continued.
        public var history: [Message]
        public var tools: [ToolSpec]
        public var parameters: GenerationParameters
        public var contextWindow: Int

        public init(model: String, systemPrompt: String? = nil, extraSystemBlocks: [String] = [], history: [Message],
                    tools: [ToolSpec] = [], parameters: GenerationParameters = .init(), contextWindow: Int) {
            self.model = model
            self.systemPrompt = systemPrompt
            self.extraSystemBlocks = extraSystemBlocks
            self.history = history
            self.tools = tools
            self.parameters = parameters
            self.contextWindow = contextWindow
        }
    }

    /// Loads attachment bytes for images referenced by ID.
    public typealias AttachmentLoader = @Sendable (String) async throws -> Data?

    public init() {}

    /// Tokens kept free for the reply when the user hasn't set max tokens.
    public static func reservedOutputTokens(contextWindow: Int, parameters: GenerationParameters) -> Int {
        if let maxTokens = parameters.maxTokens { return maxTokens }
        return min(4_096, max(256, contextWindow / 4))
    }

    public func build(_ input: Input, loadAttachment: AttachmentLoader) async throws -> (ChatRequest, ContextReport) {
        let systemText = ([input.systemPrompt] + input.extraSystemBlocks)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let systemMessage = systemText.isEmpty ? nil : ChatMessage.system(systemText)

        let reserved = Self.reservedOutputTokens(contextWindow: input.contextWindow, parameters: input.parameters)
        let fixed = (systemMessage.map(TokenEstimator.estimate) ?? 0) + TokenEstimator.estimate(input.tools)
        let budget = max(0, input.contextWindow - reserved - fixed)

        let usable = input.history.filter(Self.isSendable)
        var turns = Self.turns(of: usable)
        if let newest = turns.last { turns[turns.count - 1] = Self.fitting(newest, budget: budget) }
        var included: [[Message]] = []
        var used = 0
        for turn in turns.reversed() {
            let cost = turn.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
            if !included.isEmpty && used + cost > budget { break }
            included.insert(turn, at: 0)
            used += cost
        }
        let messages = included.flatMap { $0 }

        var chatMessages: [ChatMessage] = []
        if let systemMessage { chatMessages.append(systemMessage) }
        for (index, message) in messages.enumerated() {
            var content = try await hydrate(message.content, loadAttachment: loadAttachment)
            if message.role == .tool {
                // Tool-result images (e.g. generated images) are shown to the
                // user, not re-sent to the model.
                content = content.map { part in
                    guard case .toolResult(var result) = part else { return part }
                    result.images = []
                    return .toolResult(result)
                }
            }
            chatMessages.append(ChatMessage(role: message.role, content: content))
            // Every tool call must be answered, or providers reject the request
            // (happens when a run was cancelled between the call and its result).
            let calls = message.chatMessage.toolCalls
            if message.role == .assistant, !calls.isEmpty {
                let next = index + 1 < messages.count ? messages[index + 1] : nil
                let answered = Set((next?.role == .tool ? next?.chatMessage.toolResults : nil)?.map(\.callID) ?? [])
                let missing = calls.filter { !answered.contains($0.id) }
                if !missing.isEmpty && next?.role != .tool {
                    chatMessages.append(ChatMessage(role: .tool, content: missing.map {
                        .toolResult(ToolResult(callID: $0.id, name: $0.name, text: "The tool call was not completed.", isError: true))
                    }))
                }
            }
        }

        let request = ChatRequest(model: input.model, messages: chatMessages, tools: input.tools, parameters: input.parameters,
                                  contextWindow: input.contextWindow)
        let report = ContextReport(
            includedMessageIDs: messages.map(\.id),
            droppedMessageCount: usable.count - messages.count,
            estimatedInputTokens: fixed + used,
            budgetTokens: budget
        )
        return (request, report)
    }

    /// Failed or empty assistant placeholders are never sent back to the model.
    static func isSendable(_ message: Message) -> Bool {
        switch message.role {
        case .system: return false
        case .assistant:
            return message.content.contains { part in
                switch part {
                case .text(let t): !t.isEmpty
                case .toolCall: true
                default: false
                }
            }
        default: return !message.content.isEmpty
        }
    }

    /// Fewest tokens a shortened tool result keeps.
    static let minimumToolResultTokens = 200
    static let toolResultTrimNote = "\n\n[shortened to fit the model's context window]"

    /// Shortens the tool results in `turn` (largest first, in proportion to
    /// their size) until the turn fits `budget`. Fetched pages are the usual
    /// cause of a single turn outgrowing a small local context; without this
    /// the server would silently cut the start of the prompt instead —
    /// including the system prompt and the user's question.
    static func fitting(_ turn: [Message], budget: Int) -> [Message] {
        let cost = turn.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
        guard cost > budget else { return turn }
        var sizes: [Int] = []
        for message in turn {
            for part in message.content {
                if case .toolResult(let result) = part { sizes.append(TokenEstimator.estimate(result.text)) }
            }
        }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return turn }
        let overflow = cost - budget
        var index = 0
        return turn.map { message in
            var message = message
            message.content = message.content.map { part in
                guard case .toolResult(var result) = part else { return part }
                let size = sizes[index]
                index += 1
                let keep = max(minimumToolResultTokens, size - Int((Double(overflow) * Double(size) / Double(total)).rounded(.up)))
                guard keep < size else { return part }
                let characters = Int(Double(keep) * TokenEstimator.charactersPerToken / TokenEstimator.safetyMargin)
                result.text = String(result.text.prefix(characters)) + toolResultTrimNote
                return .toolResult(result)
            }
            return message
        }
    }

    /// Splits history into turns that each start at a user message, so tool
    /// calls and their results always stay together.
    static func turns(of messages: [Message]) -> [[Message]] {
        var turns: [[Message]] = []
        for message in messages {
            if message.role == .user || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.count - 1].append(message)
            }
        }
        // A turn can't start with a tool result.
        if let first = turns.first, first.first?.role == .tool { turns.removeFirst() }
        return turns
    }

    private func hydrate(_ parts: [ContentPart], loadAttachment: AttachmentLoader) async throws -> [ContentPart] {
        var output: [ContentPart] = []
        for part in parts {
            switch part {
            case .image(var image) where image.data == nil:
                guard let id = image.attachmentID, let data = try await loadAttachment(id) else { continue }
                image.data = data
                output.append(.image(image))
            case .reasoning:
                continue
            default:
                output.append(part)
            }
        }
        return output
    }
}
