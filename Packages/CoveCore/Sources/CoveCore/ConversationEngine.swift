import Foundation

/// Live progress of a send/regenerate, for the UI to render.
public enum EngineEvent: Sendable {
    /// A message (user, assistant step, or tool results) was persisted.
    case messageSaved(Message)
    /// A new assistant step started streaming as a child of `parentID`.
    case stepStarted(parentID: String, model: ModelRef)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallFinished(ToolCall, ToolResult)
    case usage(TokenUsage)
    /// Decode speed of the last step (shown for local models, M3).
    case tokensPerSecond(Double)
    case chatUpdated(Chat)
    case finished(FinishReason)
}

public enum EngineError: Error, LocalizedError, Sendable {
    case chatNotFound
    case messageNotFound
    case noModelSelected
    /// The model's provider can't be reached; `suggestion` is a local model
    /// to retry with (§18 "Retry with a local model").
    case offline(suggestion: ModelRef?)
    case provider(ProviderError, suggestion: ModelRef?)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .chatNotFound: "The chat no longer exists."
        case .messageNotFound: "The message no longer exists."
        case .noModelSelected: "Pick a model first."
        case .offline: "You're offline. Cloud models need a network connection."
        case .provider(let error, _): error.errorDescription
        case .other(let message): message
        }
    }

    public var localRetrySuggestion: ModelRef? {
        switch self {
        case .offline(let s), .provider(_, let s): s
        default: nil
        }
    }
}

/// Engine-wide behaviour, editable in Settings.
public struct EngineSettings: Sendable, Hashable, Codable {
    /// Prepended to every chat's system prompt.
    public var globalSystemPrompt: String?
    /// Tool names offered to the model; nil = every registered tool.
    public var enabledTools: Set<String>?
    public var defaultApprovalPolicy: ApprovalPolicy
    /// Per-tool overrides of the approval policy.
    public var toolApprovalPolicies: [String: ApprovalPolicy]
    public var maxToolSteps: Int
    public var parameters: GenerationParameters
    public var autoTitle: Bool

    public init(globalSystemPrompt: String? = nil, enabledTools: Set<String>? = nil, defaultApprovalPolicy: ApprovalPolicy = .askOnWrite,
                toolApprovalPolicies: [String: ApprovalPolicy] = [:], maxToolSteps: Int = 20,
                parameters: GenerationParameters = .init(), autoTitle: Bool = true) {
        self.globalSystemPrompt = globalSystemPrompt
        self.enabledTools = enabledTools
        self.defaultApprovalPolicy = defaultApprovalPolicy
        self.toolApprovalPolicies = toolApprovalPolicies
        self.maxToolSteps = maxToolSteps
        self.parameters = parameters
        self.autoTitle = autoTitle
    }

    public func approvalPolicy(for tool: String) -> ApprovalPolicy {
        toolApprovalPolicies[tool] ?? defaultApprovalPolicy
    }
}

/// Per-send options.
public struct SendOptions: Sendable {
    /// Overrides the chat's model for this send (e.g. "Retry with a local model").
    public var model: ModelRef?
    public var toolsEnabled: Bool
    public var parameters: GenerationParameters?

    public init(model: ModelRef? = nil, toolsEnabled: Bool = true, parameters: GenerationParameters? = nil) {
        self.model = model
        self.toolsEnabled = toolsEnabled
        self.parameters = parameters
    }
}

/// Runs the send → stream → tool-call loop (§16) and persists every step.
///
/// Each model step becomes an assistant message; tool results become a
/// `tool` message that is its child; the next step is a child of that. The
/// chat's head always points at the newest saved message.
public final class ConversationEngine: Sendable {
    private let store: any ConversationStore
    private let providers: any ProviderResolving
    private let tools: ToolRegistry
    private let approvals: ApprovalGate
    private let connectivity: any ConnectivityMonitoring
    private let attachmentSink: (any AttachmentSink)?
    private let settingsProvider: @Sendable () async -> EngineSettings
    private let contextBuilder = ContextBuilder()

    public init(store: any ConversationStore, providers: any ProviderResolving, tools: ToolRegistry, approvals: ApprovalGate,
                connectivity: any ConnectivityMonitoring, attachmentSink: (any AttachmentSink)? = nil,
                settings: @escaping @Sendable () async -> EngineSettings = { EngineSettings() }) {
        self.store = store
        self.providers = providers
        self.tools = tools
        self.approvals = approvals
        self.connectivity = connectivity
        self.attachmentSink = attachmentSink
        self.settingsProvider = settings
    }

    // MARK: Public API

    /// Appends a user message under the chat's head and runs the model.
    public func send(chatID: String, content: [ContentPart], attachmentIDs: [String] = [], options: SendOptions = .init()) -> AsyncThrowingStream<EngineEvent, Error> {
        makeStream { continuation in
            guard let chat = try await self.store.chat(id: chatID) else { throw EngineError.chatNotFound }
            let user = Message(chatID: chatID, parentID: chat.headMessageID, role: .user, content: content)
            try await self.persist(user, attachmentIDs: attachmentIDs, continuation: continuation)
            try await self.run(chatID: chatID, from: user.id, options: options, continuation: continuation)
        }
    }

    /// Replaces a user message by creating an edited sibling (a fork) and
    /// running the model from it. The original branch is kept.
    public func edit(chatID: String, userMessageID: String, newContent: [ContentPart], attachmentIDs: [String] = [], options: SendOptions = .init()) -> AsyncThrowingStream<EngineEvent, Error> {
        makeStream { continuation in
            guard let original = try await self.store.message(id: userMessageID), original.role == .user else {
                throw EngineError.messageNotFound
            }
            let edited = Message(chatID: chatID, parentID: original.parentID, role: .user, content: newContent)
            try await self.persist(edited, attachmentIDs: attachmentIDs, continuation: continuation)
            try await self.run(chatID: chatID, from: edited.id, options: options, continuation: continuation)
        }
    }

    /// Generates a new reply as a sibling of `messageID` (an assistant or
    /// tool message), i.e. a new child of the user message it answered.
    public func regenerate(chatID: String, messageID: String, options: SendOptions = .init()) -> AsyncThrowingStream<EngineEvent, Error> {
        makeStream { continuation in
            guard let target = try await self.store.message(id: messageID) else { throw EngineError.messageNotFound }
            // Walk up to the user message this reply belongs to.
            let path = try await self.store.path(to: target.id)
            guard let user = path.last(where: { $0.role == .user }) else { throw EngineError.messageNotFound }
            try await self.run(chatID: chatID, from: user.id, options: options, continuation: continuation)
        }
    }

    /// Runs the model on the branch ending at `leafID` without adding a user
    /// message (e.g. after the user forked to an earlier user message).
    public func `continue`(chatID: String, from leafID: String, options: SendOptions = .init()) -> AsyncThrowingStream<EngineEvent, Error> {
        makeStream { continuation in
            try await self.run(chatID: chatID, from: leafID, options: options, continuation: continuation)
        }
    }

    /// Added to the system prompt whenever tools are offered. Small local
    /// models otherwise tend to call tools for every message ("hey" → image).
    static let toolUsePolicy = "You have access to tools. Only call a tool when the user's request clearly needs it "
        + "(for example, current information, reading a link they gave, or an image they asked for). "
        + "For greetings, small talk, and questions you can answer yourself, reply directly without calling any tool."

    // MARK: Loop

    private func makeStream(_ body: @escaping @Sendable (AsyncThrowingStream<EngineEvent, Error>.Continuation) async throws -> Void) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(chatID: String, from startLeafID: String, options: SendOptions,
                     continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) async throws {
        guard var chat = try await store.chat(id: chatID) else { throw EngineError.chatNotFound }
        guard let model = options.model ?? chat.model else { throw EngineError.noModelSelected }
        let settings = await settingsProvider()
        let isLocal = await providers.isLocal(model.providerID)
        let isOnline = connectivity.isOnline
        if !isLocal && !isOnline {
            throw EngineError.offline(suggestion: await providers.fallbackLocalModel())
        }

        let provider = try await providers.provider(for: model)
        let contextWindow = await providers.contextWindow(for: model)
        let parameters = options.parameters ?? settings.parameters
        let toolSpecs = options.toolsEnabled && provider.capabilities.contains(.tools)
            ? tools.specs(enabled: settings.enabledTools, isOnline: isOnline) : []
        let offlineNotice = options.toolsEnabled ? tools.offlineNotice(enabled: settings.enabledTools, isOnline: isOnline) : nil
        let toolContext = ToolContext(chatID: chatID, isOnline: isOnline, attachmentSink: attachmentSink)
        let systemPrompt = [settings.globalSystemPrompt, chat.systemPrompt]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")

        var leafID = startLeafID
        let maxSteps = max(1, settings.maxToolSteps)
        for step in 0..<maxSteps {
            let history = try await store.path(to: leafID)
            var extra: [String] = []
            if !toolSpecs.isEmpty { extra.append(Self.toolUsePolicy) }
            if let offlineNotice { extra.append(offlineNotice) }
            if step == maxSteps - 1 && !toolSpecs.isEmpty {
                extra.append("This is the final step: answer now without calling tools.")
            }
            let (request, _) = try await contextBuilder.build(
                .init(model: model.modelID, systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt, extraSystemBlocks: extra,
                      history: history, tools: step == maxSteps - 1 ? [] : toolSpecs, parameters: parameters, contextWindow: contextWindow),
                loadAttachment: { [store] id in try await store.attachmentData(id: id) }
            )

            continuation.yield(.stepStarted(parentID: leafID, model: model))
            let outcome = await stream(provider: provider, request: request, continuation: continuation)

            var content: [ContentPart] = []
            if !outcome.reasoning.isEmpty { content.append(.reasoning(outcome.reasoning)) }
            if !outcome.text.isEmpty { content.append(.text(outcome.text)) }
            content += outcome.toolCalls.map(ContentPart.toolCall)

            let assistant = Message(
                chatID: chatID, parentID: leafID, role: .assistant, content: content, model: model,
                inputTokens: outcome.usage?.inputTokens, outputTokens: outcome.usage?.outputTokens,
                meta: MessageMeta(finishReason: outcome.finishReason, tokensPerSecond: outcome.tokensPerSecond,
                                  errorMessage: outcome.error?.localizedDescription, durationSeconds: outcome.duration)
            )
            try await persist(assistant, continuation: continuation)
            leafID = assistant.id
            if let usage = outcome.usage { continuation.yield(.usage(usage)) }
            if let tps = outcome.tokensPerSecond { continuation.yield(.tokensPerSecond(tps)) }

            if step == 0, settings.autoTitle, chat.title == Chat.defaultTitle,
               let title = ChatTitle.make(from: history.first(where: { $0.role == .user })?.text ?? "") {
                chat = try await store.chat(id: chatID) ?? chat
                chat.title = title
                let updated = chat
                try await detached { try await self.store.saveChat(updated) }
                continuation.yield(.chatUpdated(chat))
            }

            if let error = outcome.error {
                if case .cancelled = outcome.finishReason {
                    continuation.yield(.finished(.cancelled))
                    return
                }
                throw await mapError(error, model: model, isLocal: isLocal)
            }
            if outcome.finishReason == .cancelled || Task.isCancelled {
                continuation.yield(.finished(.cancelled))
                return
            }
            guard !outcome.toolCalls.isEmpty else {
                continuation.yield(.finished(outcome.finishReason ?? .stop))
                return
            }

            // Run the requested tools, asking for approval where the policy says so.
            var results: [ContentPart] = []
            for call in outcome.toolCalls {
                continuation.yield(.toolCallStarted(call))
                let result: ToolResult
                if let tool = tools.tool(named: call.name) {
                    let policy = settings.approvalPolicy(for: call.name)
                    if await approvals.authorize(call: call, tool: tool, policy: policy, chatID: chatID) {
                        result = await tools.invoke(call, context: toolContext)
                    } else {
                        result = ToolResult(callID: call.id, name: call.name, text: "The user declined to run this tool. Don't retry it; continue without it.", isError: true)
                    }
                } else {
                    result = ToolResult(callID: call.id, name: call.name, text: "Unknown tool \"\(call.name)\".", isError: true)
                }
                continuation.yield(.toolCallFinished(call, result))
                results.append(.toolResult(result))
                if Task.isCancelled { break }
            }
            let toolMessage = Message(chatID: chatID, parentID: leafID, role: .tool, content: results)
            try await persist(toolMessage, continuation: continuation)
            leafID = toolMessage.id
            if Task.isCancelled {
                continuation.yield(.finished(.cancelled))
                return
            }
        }
        continuation.yield(.finished(.length))
    }

    private struct StepOutcome {
        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage: TokenUsage?
        var finishReason: FinishReason?
        var error: Error?
        var tokensPerSecond: Double?
        var duration: Double?
    }

    /// Consumes one provider stream. Never throws: errors and cancellation
    /// are captured so the partial reply can still be saved.
    private func stream(provider: any LLMProvider, request: ChatRequest,
                        continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) async -> StepOutcome {
        var outcome = StepOutcome()
        let started = Date()
        var firstToken: Date?
        do {
            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    if firstToken == nil { firstToken = Date() }
                    outcome.text += delta
                    continuation.yield(.textDelta(delta))
                case .reasoningDelta(let delta):
                    if firstToken == nil { firstToken = Date() }
                    outcome.reasoning += delta
                    continuation.yield(.reasoningDelta(delta))
                case .toolCall(let call):
                    outcome.toolCalls.append(call)
                case .usage(let usage):
                    outcome.usage = outcome.usage.map { $0.merged(with: usage) } ?? usage
                case .finished(let reason):
                    outcome.finishReason = reason
                }
            }
            if Task.isCancelled { outcome.finishReason = .cancelled }
        } catch {
            if error is CancellationError || (error as? ProviderError) == .cancelled || Task.isCancelled {
                outcome.finishReason = .cancelled
            } else {
                outcome.finishReason = .error
                outcome.error = error
            }
        }
        let end = Date()
        outcome.duration = end.timeIntervalSince(started)
        if let firstToken {
            let decodeTime = end.timeIntervalSince(firstToken)
            let tokens = outcome.usage?.outputTokens ?? TokenEstimator.estimate(outcome.reasoning + outcome.text)
            if decodeTime > 0.05, tokens > 0 { outcome.tokensPerSecond = Double(tokens) / decodeTime }
        }
        return outcome
    }

    private func persist(_ message: Message, attachmentIDs: [String] = [], continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) async throws {
        // Saving must survive cancellation so a stopped reply is kept.
        try await detached {
            try await self.store.insertMessage(message)
            if !attachmentIDs.isEmpty { try await self.store.linkAttachments(attachmentIDs, to: message.id) }
            try await self.store.setHead(chatID: message.chatID, messageID: message.id)
        }
        continuation.yield(.messageSaved(message))
    }

    /// Runs `work` in an unstructured task so the caller's cancellation
    /// doesn't abort it.
    private func detached(_ work: @escaping @Sendable () async throws -> Void) async throws {
        try await Task { try await work() }.value
    }

    private func mapError(_ error: Error, model: ModelRef, isLocal: Bool) async -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        guard let providerError = error as? ProviderError else { return .other(error.localizedDescription) }
        let suggestion = (!isLocal && providerError.isConnectivityProblem) ? await providers.fallbackLocalModel() : nil
        if providerError == .offline { return .offline(suggestion: suggestion) }
        return .provider(providerError, suggestion: suggestion)
    }
}

extension TokenUsage {
    /// Providers may report usage in pieces (input first, output at the end);
    /// later non-zero values win.
    func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: other.inputTokens > 0 ? other.inputTokens : inputTokens,
            outputTokens: other.outputTokens > 0 ? other.outputTokens : outputTokens,
            reasoningTokens: other.reasoningTokens ?? reasoningTokens,
            cachedInputTokens: other.cachedInputTokens ?? cachedInputTokens
        )
    }
}

extension Chat {
    public static let defaultTitle = "New Chat"
}

/// Derives a chat title from the first user message.
public enum ChatTitle {
    public static func make(from text: String, maxLength: Int = 60) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        let prefix = collapsed.prefix(maxLength)
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > maxLength / 2 {
            return String(prefix[..<space]) + "…"
        }
        return String(prefix) + "…"
    }
}
