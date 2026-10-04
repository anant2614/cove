import Foundation

/// A model installed in Ollama (`/api/tags`).
public struct OllamaModel: Sendable, Hashable, Identifiable {
    /// The model name including tag, e.g. `llama3.2:3b`.
    public var name: String
    /// Size on disk in bytes.
    public var size: Int64
    /// E.g. "3.2B".
    public var parameterSize: String?
    /// E.g. "Q4_K_M".
    public var quantization: String?
    /// E.g. "llama".
    public var family: String?
    /// All families reported (e.g. includes "clip" for vision models).
    public var families: [String]
    public var digest: String?
    public var id: String { name }

    public init(name: String, size: Int64, parameterSize: String? = nil, quantization: String? = nil,
                family: String? = nil, families: [String] = [], digest: String? = nil) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.family = family
        self.families = families
        self.digest = digest
    }
}

/// A model currently loaded in memory (`/api/ps`).
public struct OllamaRunningModel: Sendable, Hashable, Identifiable {
    public var name: String
    /// Total size in bytes.
    public var size: Int64
    /// Bytes resident in GPU memory.
    public var sizeVRAM: Int64
    /// When Ollama will unload the model (raw RFC 3339 string).
    public var expiresAt: String?
    public var id: String { name }

    public init(name: String, size: Int64, sizeVRAM: Int64, expiresAt: String? = nil) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.expiresAt = expiresAt
    }
}

/// One progress update from `/api/pull`.
public struct OllamaPullProgress: Sendable, Hashable {
    /// E.g. "pulling manifest", "downloading", "success".
    public var status: String
    public var digest: String?
    /// Bytes downloaded so far for the current layer.
    public var completed: Int64?
    /// Total bytes for the current layer.
    public var total: Int64?

    public init(status: String, digest: String? = nil, completed: Int64? = nil, total: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.completed = completed
        self.total = total
    }

    /// Fraction complete (0…1) when sizes are known.
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// What `/api/show` reports about an installed model.
public struct OllamaModelDetails: Sendable, Hashable {
    /// E.g. ["completion", "tools", "vision", "thinking"]. Empty when the
    /// server is too old to report capabilities.
    public var capabilities: [String]
    /// The longest context the model was trained for.
    public var contextLength: Int?
    /// KV-cache size per context token at f16, from the model's shape.
    public var kvBytesPerToken: Int?
    /// KV cache that doesn't grow with the context: sliding-window layers
    /// only ever hold their window (Gemma 3/4 keep most layers this way).
    public var fixedKVBytes: Int = 0
    /// The Go chat template Ollama renders prompts with.
    public var template: String
    /// The per-layer KV head counts were withheld (Ollama omits long arrays
    /// unless asked for `verbose` output), so `kvBytesPerToken` is unknown.
    var shapeWithheld: Bool

    public init(capabilities: [String] = [], contextLength: Int? = nil, kvBytesPerToken: Int? = nil, template: String = "") {
        self.capabilities = capabilities
        self.contextLength = contextLength
        self.kvBytesPerToken = kvBytesPerToken
        self.template = template
        self.shapeWithheld = false
    }

    /// Whether the template tells the model to call a function on the user
    /// turn whenever tools are present (Llama 3.1/3.2/3.3 do: "Given the
    /// following functions, please respond with a JSON for a function call…").
    /// Such models call a tool for every message, even "hey".
    public var forcesToolCalls: Bool {
        template.contains("Given the following functions") || template.contains("and $.Tools $last")
    }

    static func parse(_ json: JSONValue) -> OllamaModelDetails {
        let info = json["model_info"]?.objectValue ?? [:]
        let arch = info["general.architecture"]?.stringValue
        func value(_ suffix: String) -> Int? {
            if let arch, let v = info["\(arch).\(suffix)"] { return largest(v) }
            return info.first { $0.key.hasSuffix(".\(suffix)") }.flatMap { largest($0.value) }
        }
        func raw(_ suffix: String) -> JSONValue? {
            if let arch, let v = info["\(arch).\(suffix)"] { return v }
            return info.first { $0.key.hasSuffix(".\(suffix)") }?.value
        }
        // KV heads per layer. Hybrid models (Qwen 3.5/3-Next: linear attention
        // with a full-attention layer every few blocks) report zeros for
        // layers that keep no KV cache.
        let blocks = value("block_count") ?? 0
        var headsPerLayer: [Int]?
        var withheld = false
        switch raw("attention.head_count_kv") {
        case .some(let heads) where heads.arrayValue != nil:
            headsPerLayer = heads.arrayValue?.compactMap(\.intValue)
        case .some(let heads) where heads.intValue != nil:
            headsPerLayer = heads.intValue.map { Array(repeating: $0, count: blocks) }
        case .some(let heads) where heads.isNull:
            withheld = true
        default:
            // No grouped-query attention: every head keeps K and V.
            headsPerLayer = value("attention.head_count").map { Array(repeating: $0, count: blocks) }
        }
        var kv: Int?
        var fixed = 0
        let keyLength = value("attention.key_length")
            ?? value("embedding_length").flatMap { width in value("attention.head_count").map { width / max(1, $0) } }
        if let headsPerLayer, let keyLength, keyLength > 0 {
            let valueLength = value("attention.value_length") ?? keyLength
            // Sliding-window layers cache at most `window` tokens, whatever the context.
            let window = value("attention.sliding_window")
            let pattern = raw("attention.sliding_window_pattern")?.arrayValue?.compactMap(\.boolValue)
            let slides = window != nil && pattern?.count == headsPerLayer.count ? pattern! : Array(repeating: false, count: headsPerLayer.count)
            let keySWA = value("attention.key_length_swa") ?? keyLength
            let valueSWA = value("attention.value_length_swa") ?? valueLength
            var perToken = 0
            for (heads, sliding) in zip(headsPerLayer, slides) {
                if sliding {
                    fixed += heads * (keySWA + valueSWA) * 2 * (window ?? 0)
                } else {
                    perToken += heads * (keyLength + valueLength) * 2  // f16
                }
            }
            kv = perToken
        }
        var details = OllamaModelDetails(
            capabilities: json["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            contextLength: value("context_length"),
            kvBytesPerToken: kv,
            template: json["template"]?.stringValue ?? ""
        )
        details.shapeWithheld = withheld
        details.fixedKVBytes = fixed
        return details
    }

    /// Some models report per-layer arrays (e.g. head_count_kv); size for the largest.
    private static func largest(_ value: JSONValue) -> Int? {
        value.intValue ?? value.arrayValue?.compactMap(\.intValue).max()
    }
}

/// KV-cache sizes read from verbose `/api/show`, keyed by server, model and
/// digest (a re-pulled model gets a new digest).
actor OllamaShapeCache {
    static let shared = OllamaShapeCache()
    private var shapes: [String: (perToken: Int, fixed: Int)] = [:]
    func shape(for key: String) -> (perToken: Int, fixed: Int)? { shapes[key] }
    func store(_ shape: (perToken: Int, fixed: Int), for key: String) { shapes[key] = shape }
}

/// A client for Ollama's native (non-OpenAI) API: model management.
public struct OllamaNativeClient: Sendable {
    /// `http://localhost:11434`.
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!  // literal, cannot fail

    /// The server root (without `/v1` or `/api`).
    public let baseURL: URL
    private let http: any HTTPClient

    /// Creates a client.
    /// - Parameters:
    ///   - baseURL: The server root; a trailing `/v1` is ignored.
    ///   - http: The transport.
    public init(baseURL: URL = OllamaNativeClient.defaultBaseURL, http: any HTTPClient) {
        self.baseURL = ProviderSupport.strippingV1(baseURL)
        self.http = http
    }

    /// Lists installed models (`GET /api/tags`).
    public func tags(timeout: TimeInterval = 10) async throws -> [OllamaModel] {
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: try ProviderSupport.url(baseURL, "api/tags"), timeout: timeout))
        return Self.parseTags(json)
    }

    /// Lists models currently loaded in memory (`GET /api/ps`).
    public func running() async throws -> [OllamaRunningModel] {
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: try ProviderSupport.url(baseURL, "api/ps"), timeout: 10))
        return (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            return OllamaRunningModel(name: name, size: Self.int64(entry["size"]), sizeVRAM: Self.int64(entry["size_vram"]),
                                      expiresAt: entry["expires_at"]?.stringValue)
        }
    }

    /// Downloads a model (`POST /api/pull`), streaming NDJSON progress.
    /// Cancelling the consuming task cancels the download.
    public func pull(_ model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let http = self.http
        let request: HTTPRequest
        do {
            request = HTTPRequest.json(try ProviderSupport.url(baseURL, "api/pull"),
                                       body: ["model": .string(model), "stream": true], timeout: 3_600)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, request)
            for try await line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let json = try? JSONValue.parse(trimmed) else {
                    throw ProviderError.invalidResponse("Malformed pull progress")
                }
                if let message = json["error"]?.stringValue {
                    throw ProviderError.http(status: 500, message: message)
                }
                continuation.yield(OllamaPullProgress(
                    status: json["status"]?.stringValue ?? "",
                    digest: json["digest"]?.stringValue,
                    completed: json["completed"]?.doubleValue.map { Int64($0) },
                    total: json["total"]?.doubleValue.map { Int64($0) }
                ))
            }
        }
    }

    /// Reads a model's capabilities, template and shape (`POST /api/show`).
    ///
    /// When the model's shape is withheld from the normal response, asks once
    /// more with `verbose` (several MB: it includes the tokenizer) and caches
    /// that per model digest, so discovery refreshes stay cheap.
    public func show(_ model: String, digest: String? = nil, timeout: TimeInterval = 10) async throws -> OllamaModelDetails {
        var details = OllamaModelDetails.parse(try await showJSON(model, verbose: false, timeout: timeout))
        guard details.shapeWithheld else { return details }
        let key = "\(baseURL.absoluteString)|\(model)|\(digest ?? "")"
        if let cached = await OllamaShapeCache.shared.shape(for: key) {
            details.kvBytesPerToken = cached.perToken
            details.fixedKVBytes = cached.fixed
        } else {
            let verbose = OllamaModelDetails.parse(try await showJSON(model, verbose: true, timeout: timeout))
            if let kv = verbose.kvBytesPerToken {
                details.kvBytesPerToken = kv
                details.fixedKVBytes = verbose.fixedKVBytes
                if digest != nil { await OllamaShapeCache.shared.store((kv, verbose.fixedKVBytes), for: key) }
            }
        }
        details.shapeWithheld = false
        return details
    }

    private func showJSON(_ model: String, verbose: Bool, timeout: TimeInterval) async throws -> JSONValue {
        var body: [String: JSONValue] = ["model": .string(model)]
        if verbose { body["verbose"] = true }
        return try await ProviderSupport.fetchJSON(http, HTTPRequest.json(try ProviderSupport.url(baseURL, "api/show"), body: .object(body), timeout: timeout))
    }

    /// `/api/show` for every model, concurrently. Models whose details can't
    /// be read within `timeout` are left out (callers fall back to name-based guesses).
    public func details(for models: [OllamaModel], timeout: TimeInterval) async -> [String: OllamaModelDetails] {
        await withTaskGroup(of: (String, OllamaModelDetails?).self) { group in
            for model in models {
                group.addTask {
                    (model.name, await LocalModelDiscovery.withTimeout(timeout) { try await self.show(model.name, digest: model.digest, timeout: timeout) })
                }
            }
            var out: [String: OllamaModelDetails] = [:]
            for await (name, details) in group { if let details { out[name] = details } }
            return out
        }
    }

    /// Installed models as `ModelInfo`, enriched with `/api/show` details.
    public func modelInfos(providerID: ProviderID, timeout: TimeInterval = 10, detailsTimeout: TimeInterval = 5) async throws -> [ModelInfo] {
        let models = try await tags(timeout: timeout)
        let details = await details(for: models, timeout: detailsTimeout)
        return models.map { OllamaProvider.modelInfo($0, details: details[$0.name], providerID: providerID) }
    }

    /// Streams a chat through the native `POST /api/chat` endpoint, which
    /// (unlike `/v1`) honours `num_ctx` and returns thinking separately.
    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let http = self.http
        let httpRequest: HTTPRequest
        do {
            httpRequest = HTTPRequest.json(try ProviderSupport.url(baseURL, "api/chat"), body: OllamaChat.requestBody(for: request), timeout: 300)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, httpRequest)
            var state = OllamaChat.StreamState()
            for try await line in lines {
                if try state.handle(line, continuation) { break }
            }
            try Task.checkCancellation()
            state.finish(continuation)
        }
    }

    static func parseTags(_ json: JSONValue) -> [OllamaModel] {
        (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            let details = entry["details"]
            return OllamaModel(
                name: name,
                size: int64(entry["size"]),
                parameterSize: details?["parameter_size"]?.stringValue,
                quantization: details?["quantization_level"]?.stringValue,
                family: details?["family"]?.stringValue,
                families: details?["families"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                digest: entry["digest"]?.stringValue
            )
        }
    }

    static func int64(_ value: JSONValue?) -> Int64 {
        value?.doubleValue.map { Int64($0) } ?? 0
    }
}

/// An `LLMProvider` for Ollama: model management and chat through the
/// native API (`/api/chat` with an explicit `num_ctx`), embeddings through `/v1`.
public struct OllamaProvider: LLMProvider {
    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    /// The native API client, for model management.
    public let native: OllamaNativeClient

    private let openAI: OpenAICompatibleProvider

    /// Creates a provider.
    /// - Parameters:
    ///   - id: The provider's id (defaults to `ProviderID.ollama`).
    ///   - baseURL: The server root; a trailing `/v1` is ignored.
    ///   - http: The transport.
    public init(id: ProviderID = .ollama, baseURL: URL = OllamaNativeClient.defaultBaseURL, http: any HTTPClient) {
        let capabilities: ProviderCapabilities = [.streaming, .tools, .vision, .embeddings]
        self.id = id
        self.capabilities = capabilities
        self.native = OllamaNativeClient(baseURL: baseURL, http: http)
        let v1 = (try? ProviderSupport.url(native.baseURL, "v1")) ?? native.baseURL
        self.openAI = OpenAICompatibleProvider(id: id, baseURL: v1, apiKey: nil, isLocal: true,
                                               capabilities: capabilities, http: http)
    }

    public func listModels() async throws -> [ModelInfo] {
        try await native.modelInfos(providerID: id)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        native.chat(request)
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        try await openAI.embed(texts, model: model)
    }

    /// Converts an installed Ollama model to a `ModelInfo`. With `details`,
    /// capabilities come from what Ollama reports; without, from the name.
    static func modelInfo(_ model: OllamaModel, details: OllamaModelDetails? = nil, providerID: ProviderID,
                          physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelInfo {
        var capabilities: ProviderCapabilities = [.streaming]
        if let reported = details?.capabilities, !reported.isEmpty {
            if reported.contains("tools") {
                capabilities.insert(.tools)
                if details?.forcesToolCalls == true { capabilities.insert(.eagerToolCalls) }
            }
            if reported.contains("vision") { capabilities.insert(.vision) }
            if reported.contains("thinking") { capabilities.insert(.reasoning) }
        } else {
            capabilities.insert(.tools)
            let lowerName = model.name.lowercased()
            let visionFamilies: Set<String> = ["clip", "mllama"]
            if !visionFamilies.isDisjoint(with: model.families) || ["llava", "vision", "gemma3", "qwen2.5vl", "minicpm-v"].contains(where: lowerName.contains) {
                capabilities.insert(.vision)
            }
        }
        var displayName = model.name
        if let size = model.parameterSize { displayName += " (\(size))" }
        return ModelInfo(id: model.name, providerID: providerID, displayName: displayName,
                         contextWindow: contextLength(for: model, details: details, physicalMemory: physicalMemory),
                         capabilities: capabilities, isLocal: true)
    }

    /// Context sizes Cove picks between (`num_ctx`). Larger windows cost
    /// memory up front, so this stops at 32K.
    static let contextSteps = [4_096, 8_192, 16_384, 32_768]

    /// The `num_ctx` Cove runs a model with: the largest step whose KV cache
    /// fits beside the weights in ~70% of RAM (about what macOS lets the GPU
    /// use), never more than the model was trained for. Sent with every
    /// request and used as the context budget, so the two always agree.
    static func contextLength(for model: OllamaModel, details: OllamaModelDetails?, physicalMemory: UInt64) -> Int {
        let trained = details?.contextLength ?? KnownModels.contextWindow(for: model.name) ?? KnownModels.defaultLocalContextWindow
        guard let kvBytes = details?.kvBytesPerToken, kvBytes > 0 else {
            return min(trained, KnownModels.defaultLocalContextWindow)
        }
        let budget = Double(physicalMemory) * 0.7 - Double(model.size) - Double(details?.fixedKVBytes ?? 0)
        var chosen = min(trained, contextSteps[0])
        for step in contextSteps where step <= trained && Double(step) * Double(kvBytes) <= budget {
            chosen = step
        }
        return chosen
    }
}

/// Request and stream mapping for Ollama's native `/api/chat`.
enum OllamaChat {
    static func requestBody(for request: ChatRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(mapMessages(request.messages)),
            "stream": true,
        ]
        var options: [String: JSONValue] = [:]
        if let window = request.contextWindow { options["num_ctx"] = .number(Double(window)) }
        let p = request.parameters
        if let value = p.temperature { options["temperature"] = .number(value) }
        if let value = p.topP { options["top_p"] = .number(value) }
        if let value = p.topK { options["top_k"] = .number(Double(value)) }
        if let value = p.maxTokens { options["num_predict"] = .number(Double(value)) }
        if let value = p.frequencyPenalty { options["frequency_penalty"] = .number(value) }
        if let value = p.presencePenalty { options["presence_penalty"] = .number(value) }
        if let stop = p.stop, !stop.isEmpty { options["stop"] = .array(stop.map { .string($0) }) }
        if !options.isEmpty { body["options"] = .object(options) }
        // Thinking models think by default; `minimal` turns it off.
        if let effort = p.reasoningEffort { body["think"] = .bool(effort != .minimal) }
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

    /// Converts Cove messages to Ollama chat messages. Tool calls carry their
    /// arguments as objects; tool results are `role: tool` with `tool_name`;
    /// images are base64 strings on the message.
    static func mapMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                out.append(["role": "system", "content": .string(OpenAICompatibleProvider.textContent(message.content))])
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant", "content": .string(OpenAICompatibleProvider.textContent(message.content))]
                let calls = message.toolCalls
                if !calls.isEmpty {
                    entry["tool_calls"] = .array(calls.map { call in
                        let arguments = (try? JSONValue.parse(call.arguments.isEmpty ? "{}" : call.arguments))
                            .flatMap { $0.objectValue != nil ? $0 : nil } ?? .object([:])
                        return ["function": ["name": .string(call.name), "arguments": arguments]]
                    })
                }
                out.append(.object(entry))
            case .user, .tool:
                for result in message.toolResults {
                    var text = result.text
                    if result.isError && !text.hasPrefix("Error") { text = "Error: " + text }
                    out.append(["role": "tool", "tool_name": .string(result.name), "content": .string(text)])
                }
                let remaining = message.content.filter {
                    if case .toolResult = $0 { return false }
                    if case .reasoning = $0 { return false }
                    return true
                }
                guard !remaining.isEmpty else { continue }
                var entry: [String: JSONValue] = ["role": "user", "content": .string(OpenAICompatibleProvider.textContent(remaining))]
                let images = remaining.compactMap { part -> JSONValue? in
                    if case .image(let image) = part, let base64 = image.base64 { return .string(base64) }
                    return nil
                }
                if !images.isEmpty { entry["images"] = .array(images) }
                out.append(.object(entry))
            }
        }
        return out
    }

    /// Accumulates `/api/chat` NDJSON lines into `ChatEvent`s.
    struct StreamState {
        private var thinkSplitter = ThinkTagSplitter()
        private var emittedToolCall = false
        private var doneReason: String?
        private var finished = false

        /// Handles one line. Returns true on the final (`done`) line.
        mutating func handle(_ line: String, _ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) throws -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            guard let json = try? JSONValue.parse(trimmed) else {
                throw ProviderError.invalidResponse("Malformed stream chunk")
            }
            if let message = json["error"]?.stringValue {
                throw ProviderError.http(status: 500, message: message)
            }
            if let message = json["message"] {
                if let thinking = message["thinking"]?.stringValue, !thinking.isEmpty {
                    continuation.yield(.reasoningDelta(thinking))
                }
                // Models without native thinking support may still inline <think> tags.
                if let text = message["content"]?.stringValue, !text.isEmpty {
                    emit(thinkSplitter.feed(text), continuation)
                }
                for call in message["tool_calls"]?.arrayValue ?? [] {
                    guard let name = call["function"]?["name"]?.stringValue, !name.isEmpty else { continue }
                    let arguments = call["function"]?["arguments"]
                    let argumentText = arguments?.stringValue ?? arguments?.jsonString() ?? "{}"
                    let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? ProviderSupport.generatedCallID()
                    continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: argumentText)))
                    emittedToolCall = true
                }
            }
            guard json["done"]?.boolValue == true else { return false }
            doneReason = json["done_reason"]?.stringValue
            if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
                continuation.yield(.usage(TokenUsage(inputTokens: json["prompt_eval_count"]?.intValue ?? 0,
                                                     outputTokens: json["eval_count"]?.intValue ?? 0)))
            }
            return true
        }

        mutating func finish(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
            emit(thinkSplitter.finish(), continuation)
            guard !finished else { return }
            finished = true
            let reason: FinishReason
            if emittedToolCall {
                reason = .toolCalls
            } else if let doneReason {
                reason = FinishReason(rawValue: doneReason)
            } else {
                reason = .stop
            }
            continuation.yield(.finished(reason))
        }

        private func emit(_ pieces: [ThinkTagSplitter.Piece], _ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
            for piece in pieces {
                switch piece {
                case .text(let text): continuation.yield(.textDelta(text))
                case .reasoning(let text): continuation.yield(.reasoningDelta(text))
                }
            }
        }
    }
}
