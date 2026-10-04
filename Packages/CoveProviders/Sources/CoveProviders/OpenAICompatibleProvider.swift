import Foundation

/// An adapter for the OpenAI Chat Completions wire protocol. Covers OpenAI,
/// OpenRouter, Mistral, Groq, LM Studio, Ollama's `/v1` endpoint and any
/// custom OpenAI-compatible server.
public struct OpenAICompatibleProvider: LLMProvider {
    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    /// The API root, e.g. `https://api.openai.com/v1`.
    public let baseURL: URL
    /// Whether the server runs on this machine (enables `top_k`, local context defaults).
    public let isLocal: Bool

    private let apiKey: String?
    private let extraHeaders: [String: String]
    private let http: any HTTPClient

    /// Creates an adapter.
    /// - Parameters:
    ///   - id: The provider's id.
    ///   - baseURL: The API root (the path that `/chat/completions` hangs off).
    ///   - apiKey: Bearer token, if the server needs one.
    ///   - extraHeaders: Headers added to every request.
    ///   - isLocal: Whether the server is local.
    ///   - capabilities: What the provider supports.
    ///   - http: The transport.
    public init(id: ProviderID, baseURL: URL, apiKey: String? = nil, extraHeaders: [String: String] = [:],
                isLocal: Bool = false, capabilities: ProviderCapabilities = .standard, http: any HTTPClient) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.isLocal = isLocal
        self.capabilities = capabilities
        self.http = http
    }

    private var host: String { baseURL.host?.lowercased() ?? "" }
    private var isOpenAI: Bool { host == "api.openai.com" }
    private var isOpenRouter: Bool { host.contains("openrouter.ai") }

    /// Headers sent with every request.
    var headers: [String: String] {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if isOpenRouter {
            headers["HTTP-Referer"] = "https://cove.app"
            headers["X-Title"] = "Cove"
        }
        headers.merge(extraHeaders) { _, extra in extra }
        return headers
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let request = HTTPRequest(url: try ProviderSupport.url(baseURL, "models"), headers: headers, timeout: 30)
        let json = try await ProviderSupport.fetchJSON(http, request)
        guard let data = json["data"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing model list")
        }
        return data.compactMap { entry -> ModelInfo? in
            guard let modelID = entry["id"]?.stringValue else { return nil }
            let window = entry["context_length"]?.intValue
                ?? entry["max_context_length"]?.intValue
                ?? KnownModels.contextWindow(for: modelID, isLocal: isLocal)
            return ModelInfo(id: modelID, providerID: id, displayName: entry["name"]?.stringValue ?? modelID,
                             contextWindow: window, capabilities: capabilities, isLocal: isLocal)
        }
    }

    // MARK: Embeddings

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        let body: JSONValue = ["model": .string(model), "input": .array(texts.map { .string($0) })]
        let request = HTTPRequest.json(try ProviderSupport.url(baseURL, "embeddings"), body: body, headers: headers)
        let json = try await ProviderSupport.fetchJSON(http, request)
        guard let data = json["data"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing embeddings")
        }
        let indexed = data.enumerated().map { offset, item in (item["index"]?.intValue ?? offset, item) }
        return try indexed.sorted { $0.0 < $1.0 }.map { _, item in
            guard let vector = ProviderSupport.floats(item["embedding"]) else {
                throw ProviderError.invalidResponse("Malformed embedding")
            }
            return vector
        }
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let http = self.http
        let httpRequest: HTTPRequest
        do {
            httpRequest = HTTPRequest.json(try ProviderSupport.url(baseURL, "chat/completions"),
                                           body: requestBody(for: request), headers: headers, timeout: 300)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, httpRequest)
            var state = OpenAIStreamState()
            for try await event in lines.sseEvents {
                if try state.handle(event, continuation) { break }
            }
            try Task.checkCancellation()
            state.finish(continuation)
        }
    }

    /// Builds the `/chat/completions` request body.
    func requestBody(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(Self.mapMessages(request.messages)),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        let p = request.parameters
        if let value = p.temperature { body["temperature"] = .number(value) }
        if let value = p.topP { body["top_p"] = .number(value) }
        if let value = p.frequencyPenalty { body["frequency_penalty"] = .number(value) }
        if let value = p.presencePenalty { body["presence_penalty"] = .number(value) }
        if let stop = p.stop, !stop.isEmpty { body["stop"] = .array(stop.map { .string($0) }) }
        if let effort = p.reasoningEffort { body["reasoning_effort"] = .string(effort.rawValue) }
        if let topK = p.topK, isLocal { body["top_k"] = .number(Double(topK)) }
        if let maxTokens = p.maxTokens {
            body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = .number(Double(maxTokens))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        return .object(body)
    }

    /// Converts Cove messages to Chat Completions messages.
    ///
    /// Tool results become `role: tool` messages. Images returned by tools
    /// can't go in a tool message, so they are noted in its text and sent in a
    /// follow-up user message once the run of tool messages ends.
    static func mapMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        var pendingToolImages: [(tool: String, image: ImageContent)] = []

        func flushToolImages() {
            guard !pendingToolImages.isEmpty else { return }
            let names = Array(Set(pendingToolImages.map(\.tool))).sorted().joined(separator: ", ")
            var parts: [JSONValue] = [["type": "text", "text": .string("Image(s) returned by tool \(names):")]]
            for item in pendingToolImages {
                if let url = item.image.dataURL {
                    parts.append(["type": "image_url", "image_url": ["url": .string(url)]])
                }
            }
            out.append(["role": "user", "content": .array(parts)])
            pendingToolImages.removeAll()
        }

        for message in messages {
            let results = message.toolResults
            let isToolMessage = message.role == .tool || (!results.isEmpty && message.role != .assistant)
            if !isToolMessage { flushToolImages() }

            switch message.role {
            case .system:
                out.append(["role": "system", "content": .string(textContent(message.content))])
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant"]
                let text = textContent(message.content)
                let calls = message.toolCalls
                entry["content"] = text.isEmpty && !calls.isEmpty ? .null : .string(text)
                if !calls.isEmpty {
                    entry["tool_calls"] = .array(calls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(call.arguments.isEmpty ? "{}" : call.arguments)],
                        ]
                    })
                }
                out.append(.object(entry))
            case .user, .tool:
                for result in results {
                    var text = result.text
                    let images = result.images.filter { $0.dataURL != nil }
                    if !images.isEmpty {
                        text += text.isEmpty ? "[image attached]" : "\n[image attached]"
                        pendingToolImages += images.map { (result.name, $0) }
                    }
                    if result.isError && !text.hasPrefix("Error") { text = "Error: " + text }
                    out.append(["role": "tool", "tool_call_id": .string(result.callID), "content": .string(text)])
                }
                let remaining = message.content.filter {
                    if case .toolResult = $0 { return false }
                    if case .reasoning = $0 { return false }
                    return true
                }
                if !remaining.isEmpty {
                    flushToolImages()
                    out.append(["role": "user", "content": userContent(remaining)])
                }
            }
        }
        flushToolImages()
        return out
    }

    /// Text of `.text` and `.file` parts, joined.
    static func textContent(_ parts: [ContentPart]) -> String {
        parts.compactMap { part -> String? in
            switch part {
            case .text(let text): text
            case .file(let file): ProviderSupport.fileBlock(file)
            default: nil
            }
        }.joined(separator: "\n\n")
    }

    /// User content: a plain string when there are no images (the most widely
    /// supported form), otherwise an array of text and image_url parts.
    static func userContent(_ parts: [ContentPart]) -> JSONValue {
        let hasImages = parts.contains { if case .image(let image) = $0 { image.data != nil } else { false } }
        guard hasImages else { return .string(textContent(parts)) }
        var blocks: [JSONValue] = []
        for part in parts {
            switch part {
            case .text(let text) where !text.isEmpty:
                blocks.append(["type": "text", "text": .string(text)])
            case .file(let file):
                blocks.append(["type": "text", "text": .string(ProviderSupport.fileBlock(file))])
            case .image(let image):
                if let url = image.dataURL {
                    blocks.append(["type": "image_url", "image_url": ["url": .string(url)]])
                }
            default:
                break
            }
        }
        return .array(blocks)
    }
}

/// Accumulates a Chat Completions stream into `ChatEvent`s.
struct OpenAIStreamState {
    private struct PartialCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var partialCalls: [Int: PartialCall] = [:]
    private var emittedToolCall = false
    private var finishReason: String?
    private var finished = false

    /// Handles one SSE event. Returns true at `[DONE]`.
    mutating func handle(_ event: SSEEvent, _ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) throws -> Bool {
        let data = event.data.trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return true }
        if data.isEmpty { return false }
        guard let json = try? JSONValue.parse(data) else {
            throw ProviderError.invalidResponse("Malformed stream chunk")
        }
        // Mid-stream errors (OpenRouter, some local servers).
        if let error = json["error"], !error.isNull {
            let status = error["code"]?.intValue ?? 500
            throw HTTPErrorMapper.error(status: status, body: data)
        }

        if let choice = json["choices"]?[0] {
            let delta = choice["delta"] ?? choice["message"]
            if let text = delta?["content"]?.stringValue, !text.isEmpty {
                continuation.yield(.textDelta(text))
            }
            if let reasoning = delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue, !reasoning.isEmpty {
                continuation.yield(.reasoningDelta(reasoning))
            }
            for (offset, callDelta) in (delta?["tool_calls"]?.arrayValue ?? []).enumerated() {
                let index = callDelta["index"]?.intValue ?? offset
                var call = partialCalls[index] ?? PartialCall()
                if let id = callDelta["id"]?.stringValue, !id.isEmpty { call.id = id }
                if let name = callDelta["function"]?["name"]?.stringValue, !name.isEmpty { call.name = name }
                if let args = callDelta["function"]?["arguments"]?.stringValue { call.arguments += args }
                partialCalls[index] = call
            }
            if let reason = choice["finish_reason"]?.stringValue {
                finishReason = reason
                flushToolCalls(continuation)
            }
        }

        if let usage = json["usage"], !usage.isNull {
            continuation.yield(.usage(TokenUsage(
                inputTokens: usage["prompt_tokens"]?.intValue ?? 0,
                outputTokens: usage["completion_tokens"]?.intValue ?? 0,
                reasoningTokens: usage["completion_tokens_details"]?["reasoning_tokens"]?.intValue,
                cachedInputTokens: usage["prompt_tokens_details"]?["cached_tokens"]?.intValue
            )))
        }
        return false
    }

    /// Emits any pending tool calls and the single `.finished` event.
    mutating func finish(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        flushToolCalls(continuation)
        guard !finished else { return }
        finished = true
        let reason: FinishReason
        if let finishReason {
            let mapped = FinishReason(rawValue: finishReason)
            // Some servers report "stop" even when they returned tool calls.
            reason = (emittedToolCall && mapped == .stop) ? .toolCalls : mapped
        } else {
            reason = emittedToolCall ? .toolCalls : .stop
        }
        continuation.yield(.finished(reason))
    }

    private mutating func flushToolCalls(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        for index in partialCalls.keys.sorted() {
            guard let call = partialCalls[index], !call.name.isEmpty else { continue }
            let id = call.id.isEmpty ? ProviderSupport.generatedCallID() : call.id
            continuation.yield(.toolCall(ToolCall(id: id, name: call.name, arguments: call.arguments)))
            emittedToolCall = true
        }
        partialCalls.removeAll()
    }
}
