import Foundation

/// An adapter for the Anthropic Messages API.
public struct AnthropicProvider: LLMProvider {
    /// The API version header value.
    public static let apiVersion = "2023-06-01"
    /// `max_tokens` is required by the API; used when the request sets none.
    public static let defaultMaxTokens = 8_192
    /// Context window reported for every Claude model.
    public static let contextWindow = 200_000

    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    /// The API root, e.g. `https://api.anthropic.com`.
    public let baseURL: URL

    private let apiKey: String
    private let http: any HTTPClient

    /// Creates an adapter.
    /// - Parameters:
    ///   - id: The provider's id.
    ///   - baseURL: The API root (with or without a trailing `/v1`); defaults to `https://api.anthropic.com`.
    ///   - apiKey: The `x-api-key` value.
    ///   - capabilities: What the provider supports.
    ///   - http: The transport.
    public init(id: ProviderID, baseURL: URL? = nil, apiKey: String,
                capabilities: ProviderCapabilities = [.streaming, .vision, .tools, .reasoning], http: any HTTPClient) {
        self.id = id
        self.baseURL = ProviderSupport.strippingV1(baseURL ?? Self.defaultBaseURL)
        self.apiKey = apiKey
        self.capabilities = capabilities
        self.http = http
    }

    /// `https://api.anthropic.com`.
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!  // literal, cannot fail

    var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": Self.apiVersion]
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let url = try ProviderSupport.url(baseURL, "v1/models", query: [URLQueryItem(name: "limit", value: "1000")])
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: url, headers: headers, timeout: 30))
        guard let data = json["data"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing model list")
        }
        return data.compactMap { entry in
            guard let modelID = entry["id"]?.stringValue else { return nil }
            return ModelInfo(id: modelID, providerID: id, displayName: entry["display_name"]?.stringValue,
                             contextWindow: Self.contextWindow, capabilities: capabilities, isLocal: false)
        }
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let http = self.http
        let httpRequest: HTTPRequest
        do {
            httpRequest = HTTPRequest.json(try ProviderSupport.url(baseURL, "v1/messages"),
                                           body: requestBody(for: request), headers: headers, timeout: 300)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, httpRequest)
            var state = AnthropicStreamState()
            for try await event in lines.sseEvents {
                if try state.handle(event, continuation) { break }
            }
            try Task.checkCancellation()
            state.finish(continuation)
        }
    }

    /// Thinking budget for a reasoning effort (nil = thinking off).
    static func thinkingBudget(for effort: ReasoningEffort?) -> Int? {
        switch effort {
        case .low: 2_048
        case .medium: 8_192
        case .high: 24_576
        case .minimal, nil: nil
        }
    }

    /// Builds the `/v1/messages` request body.
    func requestBody(for request: ChatRequest) -> JSONValue {
        let p = request.parameters
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(Self.mapMessages(request.messages)),
            "stream": true,
        ]

        // System prompt: one text block per system message; the last block
        // carries the prompt-caching breakpoint.
        var systemBlocks: [JSONValue] = request.messages
            .filter { $0.role == .system }
            .map { OpenAICompatibleProvider.textContent($0.content) }
            .filter { !$0.isEmpty }
            .map { ["type": "text", "text": .string($0)] }
        if !systemBlocks.isEmpty, case .object(var last) = systemBlocks[systemBlocks.count - 1] {
            last["cache_control"] = ["type": "ephemeral"]
            systemBlocks[systemBlocks.count - 1] = .object(last)
            body["system"] = .array(systemBlocks)
        }

        var maxTokens = p.maxTokens ?? Self.defaultMaxTokens
        if let budget = Self.thinkingBudget(for: p.reasoningEffort) {
            body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(budget))]
            if maxTokens <= budget { maxTokens = budget + Self.defaultMaxTokens }
        } else {
            if let value = p.temperature { body["temperature"] = .number(value) }
            if let value = p.topP { body["top_p"] = .number(value) }
            if let value = p.topK { body["top_k"] = .number(Double(value)) }
        }
        body["max_tokens"] = .number(Double(maxTokens))
        if let stop = p.stop, !stop.isEmpty { body["stop_sequences"] = .array(stop.map { .string($0) }) }

        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema]
            })
        }
        return .object(body)
    }

    /// Converts non-system messages to Anthropic messages, merging consecutive
    /// same-role turns (the API requires alternation).
    static func mapMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var turns: [(role: String, blocks: [JSONValue])] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "assistant" : "user"
            let blocks = contentBlocks(message)
            guard !blocks.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append((role, blocks))
            }
        }
        return turns.map { turn in
            var blocks = turn.blocks
            if turn.role == "user" {
                // tool_result blocks must precede other content in a user turn.
                let results = blocks.filter { $0["type"]?.stringValue == "tool_result" }
                let others = blocks.filter { $0["type"]?.stringValue != "tool_result" }
                blocks = results + others
            }
            return ["role": .string(turn.role), "content": .array(blocks)]
        }
    }

    static func contentBlocks(_ message: ChatMessage) -> [JSONValue] {
        var blocks: [JSONValue] = []
        for part in message.content {
            switch part {
            case .text(let text):
                if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
            case .file(let file):
                blocks.append(["type": "text", "text": .string(ProviderSupport.fileBlock(file))])
            case .image(let image):
                if let block = imageBlock(image) { blocks.append(block) }
            case .reasoning:
                // Thinking blocks can't be replayed without their signatures.
                break
            case .toolCall(let call):
                let input = (try? JSONValue.parse(call.arguments)) ?? .object([:])
                blocks.append([
                    "type": "tool_use",
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": input.objectValue != nil ? input : .object([:]),
                ])
            case .toolResult(let result):
                var content: [JSONValue] = []
                if !result.text.isEmpty { content.append(["type": "text", "text": .string(result.text)]) }
                content += result.images.compactMap(imageBlock)
                var block: [String: JSONValue] = [
                    "type": "tool_result",
                    "tool_use_id": .string(result.callID),
                    "content": .array(content),
                ]
                if result.isError { block["is_error"] = true }
                blocks.append(.object(block))
            }
        }
        return blocks
    }

    static func imageBlock(_ image: ImageContent) -> JSONValue? {
        guard let data = image.base64 else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": .string(image.mime), "data": .string(data)]]
    }
}

/// Accumulates an Anthropic Messages stream into `ChatEvent`s.
struct AnthropicStreamState {
    private struct PartialToolUse {
        var id: String
        var name: String
        var json: String = ""
    }

    private var toolBlocks: [Int: PartialToolUse] = [:]
    private var inputTokens = 0
    private var cachedTokens: Int?
    private var outputTokens = 0
    private var stopReason: String?
    private var emittedToolCall = false
    private var finished = false

    /// Error `type` → HTTP status, so stream errors share the HTTP mapping.
    static let errorStatus: [String: Int] = [
        "invalid_request_error": 400, "authentication_error": 401, "permission_error": 403,
        "not_found_error": 404, "request_too_large": 413, "rate_limit_error": 429,
        "api_error": 500, "overloaded_error": 529,
    ]

    /// Handles one SSE event. Returns true at `message_stop`.
    mutating func handle(_ event: SSEEvent, _ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) throws -> Bool {
        guard let json = try? JSONValue.parse(event.data) else {
            throw ProviderError.invalidResponse("Malformed stream event")
        }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "message_start":
            let usage = json["message"]?["usage"]
            inputTokens = usage?["input_tokens"]?.intValue ?? 0
            outputTokens = usage?["output_tokens"]?.intValue ?? 0
            let cacheRead = usage?["cache_read_input_tokens"]?.intValue ?? 0
            let cacheWrite = usage?["cache_creation_input_tokens"]?.intValue ?? 0
            if cacheRead > 0 { cachedTokens = cacheRead }
            // Report total prompt size: uncached + cache reads + cache writes.
            inputTokens += cacheRead + cacheWrite

        case "content_block_start":
            let block = json["content_block"]
            if block?["type"]?.stringValue == "tool_use", let index = json["index"]?.intValue {
                toolBlocks[index] = PartialToolUse(id: block?["id"]?.stringValue ?? ProviderSupport.generatedCallID(),
                                                   name: block?["name"]?.stringValue ?? "")
            }

        case "content_block_delta":
            let delta = json["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta":
                if let text = delta?["text"]?.stringValue, !text.isEmpty { continuation.yield(.textDelta(text)) }
            case "thinking_delta":
                if let text = delta?["thinking"]?.stringValue, !text.isEmpty { continuation.yield(.reasoningDelta(text)) }
            case "input_json_delta":
                if let index = json["index"]?.intValue, let fragment = delta?["partial_json"]?.stringValue {
                    toolBlocks[index]?.json += fragment
                }
            default:
                break // signature_delta, citations_delta, …
            }

        case "content_block_stop":
            if let index = json["index"]?.intValue, let tool = toolBlocks.removeValue(forKey: index) {
                let arguments = tool.json.isEmpty ? "{}" : tool.json
                continuation.yield(.toolCall(ToolCall(id: tool.id, name: tool.name, arguments: arguments)))
                emittedToolCall = true
            }

        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let output = json["usage"]?["output_tokens"]?.intValue { outputTokens = output }
            continuation.yield(.usage(TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens,
                                                 cachedInputTokens: cachedTokens)))

        case "message_stop":
            return true

        case "error":
            let errorType = json["error"]?["type"]?.stringValue ?? ""
            throw HTTPErrorMapper.error(status: Self.errorStatus[errorType] ?? 500, body: event.data)

        default:
            break // ping and future event types
        }
        return false
    }

    /// Emits any unterminated tool calls and the single `.finished` event.
    mutating func finish(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        for index in toolBlocks.keys.sorted() {
            guard let tool = toolBlocks[index] else { continue }
            continuation.yield(.toolCall(ToolCall(id: tool.id, name: tool.name, arguments: tool.json.isEmpty ? "{}" : tool.json)))
            emittedToolCall = true
        }
        toolBlocks.removeAll()
        guard !finished else { return }
        finished = true
        let reason = stopReason.map(FinishReason.init(rawValue:)) ?? (emittedToolCall ? .toolCalls : .stop)
        continuation.yield(.finished(reason))
    }
}
