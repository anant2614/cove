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
        /// Text appended to each user-typed message, from when it was sent
        /// (e.g. "(sent Sun 4 Oct, 21:15)"). Derived from the message itself,
        /// so a message reads the same in every later request and servers can
        /// keep reusing their cached prompt prefix.
        public var userMessageNote: (@Sendable (Date) -> String)?

        public init(model: String, systemPrompt: String? = nil, extraSystemBlocks: [String] = [], history: [Message],
                    tools: [ToolSpec] = [], parameters: GenerationParameters = .init(), contextWindow: Int,
                    userMessageNote: (@Sendable (Date) -> String)? = nil) {
            self.model = model
            self.systemPrompt = systemPrompt
            self.extraSystemBlocks = extraSystemBlocks
            self.history = history
            self.tools = tools
            self.parameters = parameters
            self.contextWindow = contextWindow
            self.userMessageNote = userMessageNote
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

        // Cost and fit exactly what is sent: no reasoning, no tool-result images,
        // user messages with their time note.
        let usable = input.history.filter(Self.isSendable).map { Self.outgoing($0, note: input.userMessageNote) }
        var turns = Self.turns(of: usable)
        if let newest = turns.last {
            // When the newest turn has its own large tool output, leave room
            // for the previous exchange in short form, so a follow-up still
            // has the conversation it follows (up to a quarter of the budget).
            var room = budget
            if turns.count > 1 {
                let previous = Self.cost(of: Self.withToolOutputOmitted(turns[turns.count - 2]))
                if previous <= budget / 4 { room -= previous }
            }
            turns[turns.count - 1] = Self.fitting(newest, budget: room)
        }
        var included: [[Message]] = []
        var used = 0
        for turn in turns.reversed() {
            var candidate = turn
            if !included.isEmpty && used + Self.cost(of: candidate) > budget {
                // Keep the earlier exchange (question, calls, answers) and drop
                // only as much of its bulky tool output as needed, largest first.
                candidate = Self.shrinkingToolOutput(turn, toFit: budget - used)
                if used + Self.cost(of: candidate) > budget { break }
            }
            included.insert(candidate, at: 0)
            used += Self.cost(of: candidate)
        }
        let messages = included.flatMap { $0 }

        var chatMessages: [ChatMessage] = []
        if let systemMessage { chatMessages.append(systemMessage) }
        for (index, message) in messages.enumerated() {
            let content = try await hydrate(message.content, loadAttachment: loadAttachment)
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

    /// A message as it will be sent: reasoning is never re-sent, tool-result
    /// images (e.g. generated images) are shown to the user but not re-sent,
    /// and user-typed messages carry their time note.
    static func outgoing(_ message: Message, note: (@Sendable (Date) -> String)?) -> Message {
        var message = message
        message.content = message.content.compactMap { part in
            switch part {
            case .reasoning: return nil
            case .toolResult(var result) where message.role == .tool:
                result.images = []
                return .toolResult(result)
            default: return part
            }
        }
        if message.role == .user, let note, !message.content.contains(where: { if case .toolResult = $0 { true } else { false } }) {
            message.content.append(.text(note(message.createdAt)))
        }
        return message
    }

    static func cost(of turn: [Message]) -> Int {
        turn.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
    }

    /// Fewest tokens a shortened tool result keeps (unless even that can't fit).
    static let minimumToolResultTokens = 200
    static let toolResultTrimNote = "\n\n[shortened to fit the model's context window]"
    static let omittedToolOutput = "[earlier tool output omitted to fit the context window]"

    /// The turn with every tool result replaced by a short stub. Calls and
    /// results stay paired, so providers still accept the history.
    static func withToolOutputOmitted(_ turn: [Message]) -> [Message] {
        var turn = turn
        for slot in toolResultSlots(turn) { stub(slot, in: &turn) }
        return turn
    }

    /// Replaces tool results with the stub, largest first, until the turn
    /// costs at most `budget` (or there is nothing left worth stubbing).
    static func shrinkingToolOutput(_ turn: [Message], toFit budget: Int) -> [Message] {
        var turn = turn
        let stubCost = TokenEstimator.estimate(omittedToolOutput)
        let bySize = toolResultSlots(turn).sorted { TokenEstimator.estimate(text($0, in: turn)) > TokenEstimator.estimate(text($1, in: turn)) }
        for slot in bySize where cost(of: turn) > budget {
            guard TokenEstimator.estimate(text(slot, in: turn)) > stubCost else { break }
            stub(slot, in: &turn)
        }
        return turn
    }

    /// Shortens the tool results in `turn` until it fits `budget`: results
    /// over a common cap are cut to it, the largest first. If even
    /// `minimumToolResultTokens` per result doesn't fit, older results are
    /// replaced by a stub (oldest first, skipping ones smaller than the stub),
    /// keeping the newest. Fetched pages are the usual cause of a single turn
    /// outgrowing a small local context; without this the server would cut
    /// the start of the prompt instead, or reject the request.
    static func fitting(_ turn: [Message], budget: Int) -> [Message] {
        var turn = turn
        guard cost(of: turn) > budget else { return turn }
        let slots = toolResultSlots(turn)
        guard !slots.isEmpty else { return turn }
        let noteCost = TokenEstimator.estimate(toolResultTrimNote)
        let stubCost = TokenEstimator.estimate(omittedToolOutput)
        var stubbed: Set<Int> = []
        while true {
            let open = slots.indices.filter { !stubbed.contains($0) }.map { slots[$0] }
            let sizes = open.map { TokenEstimator.estimate(text($0, in: turn)) }
            let room = budget - (cost(of: turn) - sizes.reduce(0, +))
            if sizes.reduce(0, +) <= room { return turn }
            // Cost of capping every open result at c; monotone in c (a result
            // is only cut when that makes it cheaper, note included).
            func needed(_ c: Int) -> Int { sizes.reduce(0) { $0 + min($1, c + noteCost) } }
            if needed(minimumToolResultTokens) <= room || open.count == 1 {
                var low = 0, high = sizes.max() ?? 0
                while low < high {
                    let mid = (low + high + 1) / 2
                    if needed(mid) <= room { low = mid } else { high = mid - 1 }
                }
                for (slot, size) in zip(open, sizes) where size > low + noteCost {
                    let characters = Int(Double(low) * TokenEstimator.charactersPerToken / TokenEstimator.safetyMargin)
                    setText(String(text(slot, in: turn).prefix(characters)) + toolResultTrimNote, at: slot, in: &turn)
                }
                return turn
            }
            // Floors don't fit: stub the oldest result that is worth stubbing.
            guard let next = slots.indices.dropLast().first(where: {
                !stubbed.contains($0) && TokenEstimator.estimate(text(slots[$0], in: turn)) > stubCost
            }) else {
                // Nothing older is worth stubbing: cut everything to what fits.
                stubbed = Set(slots.indices.dropLast())
                for index in stubbed where TokenEstimator.estimate(text(slots[index], in: turn)) > stubCost { stub(slots[index], in: &turn) }
                continue
            }
            stub(slots[next], in: &turn)
            stubbed.insert(next)
        }
    }

    /// (message, part) positions of the tool results in `turn`, oldest first.
    private static func toolResultSlots(_ turn: [Message]) -> [(Int, Int)] {
        var slots: [(Int, Int)] = []
        for (m, message) in turn.enumerated() {
            for (p, part) in message.content.enumerated() { if case .toolResult = part { slots.append((m, p)) } }
        }
        return slots
    }

    private static func text(_ slot: (Int, Int), in turn: [Message]) -> String {
        if case .toolResult(let result) = turn[slot.0].content[slot.1] { return result.text }
        return ""
    }

    private static func setText(_ value: String, at slot: (Int, Int), in turn: inout [Message]) {
        guard case .toolResult(var result) = turn[slot.0].content[slot.1] else { return }
        result.text = value
        turn[slot.0].content[slot.1] = .toolResult(result)
    }

    private static func stub(_ slot: (Int, Int), in turn: inout [Message]) {
        guard case .toolResult(var result) = turn[slot.0].content[slot.1] else { return }
        result.text = omittedToolOutput
        result.images = []
        turn[slot.0].content[slot.1] = .toolResult(result)
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
