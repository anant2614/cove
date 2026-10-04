import Foundation

/// An adapter for the Google Gemini (Generative Language) API.
public struct GeminiProvider: LLMProvider {
    /// `https://generativelanguage.googleapis.com`.
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com")!  // literal, cannot fail

    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    /// The API root (the path that `/v1beta` hangs off).
    public let baseURL: URL

    private let apiKey: String
    private let http: any HTTPClient

    /// Creates an adapter.
    /// - Parameters:
    ///   - id: The provider's id.
    ///   - baseURL: The API root; defaults to `https://generativelanguage.googleapis.com`.
    ///   - apiKey: The `x-goog-api-key` value.
    ///   - capabilities: What the provider supports.
    ///   - http: The transport.
    public init(id: ProviderID, baseURL: URL? = nil, apiKey: String,
                capabilities: ProviderCapabilities = [.streaming, .vision, .tools, .reasoning, .embeddings],
                http: any HTTPClient) {
        var root = (baseURL ?? Self.defaultBaseURL).absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1beta") { root.removeLast(7) }
        self.baseURL = URL(string: root) ?? Self.defaultBaseURL
        self.id = id
        self.apiKey = apiKey
        self.capabilities = capabilities
        self.http = http
    }

    var headers: [String: String] { ["x-goog-api-key": apiKey] }

    /// Model ids may be given with or without the `models/` prefix.
    static func bareModelID(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let url = try ProviderSupport.url(baseURL, "v1beta/models", query: [URLQueryItem(name: "pageSize", value: "1000")])
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: url, headers: headers, timeout: 30))
        guard let models = json["models"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing model list")
        }
        return models.compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            let methods = entry["supportedGenerationMethods"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard methods.contains("generateContent") else { return nil }
            let modelID = Self.bareModelID(name)
            return ModelInfo(id: modelID, providerID: id, displayName: entry["displayName"]?.stringValue,
                             contextWindow: entry["inputTokenLimit"]?.intValue ?? KnownModels.contextWindow(for: modelID, isLocal: false),
                             capabilities: capabilities.subtracting(.embeddings), isLocal: false)
        }
    }

    // MARK: Embeddings

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        let bare = Self.bareModelID(model)
        let body: JSONValue = ["requests": .array(texts.map { text in
            ["model": .string("models/\(bare)"), "content": ["parts": [["text": .string(text)]]]]
        })]
        let url = try ProviderSupport.url(baseURL, "v1beta/models/\(bare):batchEmbedContents")
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest.json(url, body: body, headers: headers))
        guard let embeddings = json["embeddings"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing embeddings")
        }
        return try embeddings.map { item in
            guard let values = ProviderSupport.floats(item["values"]) else {
                throw ProviderError.invalidResponse("Malformed embedding")
            }
            return values
        }
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let http = self.http
        let httpRequest: HTTPRequest
        do {
            let url = try ProviderSupport.url(baseURL, "v1beta/models/\(Self.bareModelID(request.model)):streamGenerateContent",
                                              query: [URLQueryItem(name: "alt", value: "sse")])
            httpRequest = HTTPRequest.json(url, body: requestBody(for: request), headers: headers, timeout: 300)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, httpRequest)
            var state = GeminiStreamState()
            for try await event in lines.sseEvents {
                try state.handle(event, continuation)
            }
            try Task.checkCancellation()
            state.finish(continuation)
        }
    }

    /// Thinking budget for a reasoning effort.
    static func thinkingBudget(for effort: ReasoningEffort) -> Int {
        switch effort {
        case .minimal: 128 // the smallest budget every thinking model accepts
        case .low: 2_048
        case .medium: 8_192
        case .high: 24_576
        }
    }

    /// Builds the `streamGenerateContent` request body.
    func requestBody(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = ["contents": .array(Self.mapContents(request.messages))]

        let systemText = request.messages
            .filter { $0.role == .system }
            .map { OpenAICompatibleProvider.textContent($0.content) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": .string(systemText)]]]
        }

        if !request.tools.isEmpty {
            let declarations: [JSONValue] = request.tools.map { tool in
                var declaration: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description)]
                let schema = Self.sanitizeSchema(tool.inputSchema)
                // Gemini rejects an object schema with no properties; omit it instead.
                if let properties = schema["properties"]?.objectValue, !properties.isEmpty {
                    declaration["parameters"] = schema
                }
                return .object(declaration)
            }
            body["tools"] = [["functionDeclarations": .array(declarations)]]
        }

        let p = request.parameters
        var config: [String: JSONValue] = [:]
        if let value = p.temperature { config["temperature"] = .number(value) }
        if let value = p.topP { config["topP"] = .number(value) }
        if let value = p.topK { config["topK"] = .number(Double(value)) }
        if let value = p.maxTokens { config["maxOutputTokens"] = .number(Double(value)) }
        if let stop = p.stop, !stop.isEmpty { config["stopSequences"] = .array(stop.map { .string($0) }) }
        if let effort = p.reasoningEffort {
            config["thinkingConfig"] = ["thinkingBudget": .number(Double(Self.thinkingBudget(for: effort))), "includeThoughts": true]
        }
        if !config.isEmpty { body["generationConfig"] = .object(config) }
        return .object(body)
    }

    /// Converts non-system messages to Gemini `contents`, merging consecutive
    /// same-role turns.
    static func mapContents(_ messages: [ChatMessage]) -> [JSONValue] {
        var turns: [(role: String, parts: [JSONValue])] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "model" : "user"
            var parts: [JSONValue] = []
            for part in message.content {
                switch part {
                case .text(let text):
                    if !text.isEmpty { parts.append(["text": .string(text)]) }
                case .file(let file):
                    parts.append(["text": .string(ProviderSupport.fileBlock(file))])
                case .image(let image):
                    if let block = inlineData(image) { parts.append(block) }
                case .reasoning:
                    break
                case .toolCall(let call):
                    let args = (try? JSONValue.parse(call.arguments)) ?? .object([:])
                    parts.append(["functionCall": ["name": .string(call.name), "args": args.objectValue != nil ? args : .object([:])]])
                case .toolResult(let result):
                    var response: [String: JSONValue] = ["result": .string(result.text)]
                    if result.isError { response = ["error": .string(result.text)] }
                    parts.append(["functionResponse": ["name": .string(result.name), "response": .object(response)]])
                    parts += result.images.compactMap(inlineData)
                }
            }
            guard !parts.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].parts += parts
            } else {
                turns.append((role, parts))
            }
        }
        return turns.map { ["role": .string($0.role), "parts": .array($0.parts)] }
    }

    static func inlineData(_ image: ImageContent) -> JSONValue? {
        guard let data = image.base64 else { return nil }
        return ["inlineData": ["mimeType": .string(image.mime), "data": .string(data)]]
    }

    /// Keys Gemini's OpenAPI-subset schema accepts.
    static let allowedSchemaKeys: Set<String> = [
        "type", "properties", "required", "items", "enum", "description", "format", "nullable", "anyOf",
    ]

    /// Strips JSON-Schema keys Gemini rejects (`$schema`, `additionalProperties`,
    /// `default`, …) and rewrites `type: [T, "null"]` as `type: T, nullable: true`.
    static func sanitizeSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(let object) = schema else { return schema }
        var out: [String: JSONValue] = [:]
        for (key, value) in object where allowedSchemaKeys.contains(key) {
            switch key {
            case "properties":
                if case .object(let properties) = value {
                    out[key] = .object(properties.mapValues(sanitizeSchema))
                }
            case "items":
                out[key] = sanitizeSchema(value)
            case "anyOf":
                if case .array(let options) = value { out[key] = .array(options.map(sanitizeSchema)) }
            case "type":
                if case .array(let types) = value {
                    let names = types.compactMap(\.stringValue)
                    if let first = names.first(where: { $0 != "null" }) { out["type"] = .string(first) }
                    if names.contains("null") { out["nullable"] = true }
                } else {
                    out[key] = value
                }
            case "enum":
                // Gemini only accepts string enums.
                if case .array(let values) = value {
                    out[key] = .array(values.map { item in
                        if case .number(let number) = item { return .string(JSONValue.number(number).jsonString()) }
                        return item
                    })
                }
            case "format":
                // Only these formats are accepted for strings.
                if let format = value.stringValue, ["enum", "date-time"].contains(format) || object["type"]?.stringValue != "string" {
                    out[key] = value
                }
            default:
                out[key] = value
            }
        }
        return .object(out)
    }
}

/// Accumulates a Gemini SSE stream into `ChatEvent`s.
struct GeminiStreamState {
    private var usage: TokenUsage?
    private var finishReason: String?
    private var emittedToolCall = false
    private var finished = false

    mutating func handle(_ event: SSEEvent, _ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) throws {
        guard let json = try? JSONValue.parse(event.data) else {
            throw ProviderError.invalidResponse("Malformed stream chunk")
        }
        if let error = json["error"], !error.isNull {
            throw HTTPErrorMapper.error(status: error["code"]?.intValue ?? 500, body: event.data)
        }
        if let candidate = json["candidates"]?[0] {
            for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                if let text = part["text"]?.stringValue, !text.isEmpty {
                    if part["thought"]?.boolValue == true {
                        continuation.yield(.reasoningDelta(text))
                    } else {
                        continuation.yield(.textDelta(text))
                    }
                }
                if let call = part["functionCall"], let name = call["name"]?.stringValue {
                    let args = call["args"] ?? .object([:])
                    let id = call["id"]?.stringValue ?? ProviderSupport.generatedCallID()
                    continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: args.jsonString())))
                    emittedToolCall = true
                }
            }
            if let reason = candidate["finishReason"]?.stringValue { finishReason = reason }
        }
        // usageMetadata is cumulative; report the last one at the end.
        if let meta = json["usageMetadata"] {
            usage = TokenUsage(
                inputTokens: meta["promptTokenCount"]?.intValue ?? 0,
                outputTokens: (meta["candidatesTokenCount"]?.intValue ?? 0) + (meta["thoughtsTokenCount"]?.intValue ?? 0),
                reasoningTokens: meta["thoughtsTokenCount"]?.intValue,
                cachedInputTokens: meta["cachedContentTokenCount"]?.intValue
            )
        }
    }

    mutating func finish(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        guard !finished else { return }
        finished = true
        if let usage { continuation.yield(.usage(usage)) }
        let mapped = finishReason.map(FinishReason.init(rawValue:)) ?? .stop
        continuation.yield(.finished(emittedToolCall && mapped == .stop ? .toolCalls : mapped))
    }
}
