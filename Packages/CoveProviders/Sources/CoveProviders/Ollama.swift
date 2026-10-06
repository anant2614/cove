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
    /// Capabilities listed by `/api/tags` (Ollama 0.35+; empty on older servers).
    public var capabilities: [String]
    /// Trained context length listed by `/api/tags` (Ollama 0.35+).
    public var contextLength: Int?
    public var id: String { name }

    public init(name: String, size: Int64, parameterSize: String? = nil, quantization: String? = nil,
                family: String? = nil, families: [String] = [], digest: String? = nil,
                capabilities: [String] = [], contextLength: Int? = nil) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.family = family
        self.families = families
        self.digest = digest
        self.capabilities = capabilities
        self.contextLength = contextLength
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
            let perLayer = heads.arrayValue?.compactMap(\.intValue) ?? []
            if perLayer.count == blocks, blocks > 0 { headsPerLayer = perLayer } else { withheld = true }
        case .some(let heads) where heads.intValue != nil:
            headsPerLayer = heads.intValue.map { n in
                // Hybrid GGUFs may give one number plus the full-attention interval:
                // only every k-th layer keeps a KV cache.
                guard let k = value("full_attention_interval"), k > 1 else { return Array(repeating: n, count: blocks) }
                return (0..<blocks).map { ($0 + 1) % k == 0 ? n : 0 }
            }
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
            let slides = Self.slidingLayers(count: headsPerLayer.count, window: window,
                                            pattern: raw("attention.sliding_window_pattern"), architecture: arch)
            let keySWA = value("attention.key_length_swa") ?? keyLength
            let valueSWA = value("attention.value_length_swa") ?? valueLength
            var perToken = 0
            for (heads, sliding) in zip(headsPerLayer, slides) {
                if sliding {
                    fixed += heads * (keySWA + valueSWA) * 2 * Self.slidingCacheCells(window: window ?? 0)
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

    /// Cells llama.cpp keeps per sliding-window layer: the window plus one
    /// micro-batch (Ollama runs it with 512), padded to 256.
    static func slidingCacheCells(window: Int) -> Int {
        guard window > 0 else { return 0 }
        return (window + 512 + 255) / 256 * 256
    }

    /// Every n-th layer attends globally, the rest over a sliding window, for
    /// architectures whose GGUF has a window but no pattern key (llama.cpp
    /// hard-codes these: gemma3 6, gemma3n 5, gemma2 and gpt-oss 2, cohere2 4).
    static let defaultSlidingPattern: [String: Int] = ["gemma3": 6, "gemma3n": 5, "gemma2": 2, "gptoss": 2, "gpt-oss": 2, "cohere2": 4]

    /// Which layers use the sliding window: an explicit per-layer pattern, an
    /// integer period, or the architecture's known period. Unknown layouts
    /// count every layer as global (overestimates memory, never underestimates).
    static func slidingLayers(count: Int, window: Int?, pattern: JSONValue?, architecture: String?) -> [Bool] {
        let none = Array(repeating: false, count: count)
        guard let window, window > 0 else { return none }
        if let flags = pattern?.arrayValue?.compactMap(\.boolValue), flags.count == count { return flags }
        let period = pattern?.intValue ?? architecture.flatMap { defaultSlidingPattern[$0] }
        guard let period, period > 1 else { return none }
        return (0..<count).map { $0 % period < period - 1 }
    }

    /// Some models report per-layer arrays (e.g. head_count_kv); size for the largest.
    private static func largest(_ value: JSONValue) -> Int? {
        value.intValue ?? value.arrayValue?.compactMap(\.intValue).max()
    }
}

/// `/api/show` results keyed by server, model and digest. A digest's details
/// never change (re-pulling gives a new digest), so discovery reads each model
/// once instead of every refresh, and a slow or failed read later can't
/// replace real capabilities with name-based guesses.
actor OllamaDetailsCache {
    static let shared = OllamaDetailsCache()
    /// How long before a withheld shape is asked for again (the verbose
    /// response is several MB and slow to parse).
    static let shapeRetryInterval: TimeInterval = 600
    private var entries: [String: OllamaModelDetails] = [:]
    private var shapeAttempts: [String: Date] = [:]

    func details(for key: String) -> OllamaModelDetails? { entries[key] }

    /// Stores `details` unless that would replace a complete entry with one
    /// whose shape is still withheld (two probes can overlap).
    func store(_ details: OllamaModelDetails, for key: String) {
        if let existing = entries[key], !existing.shapeWithheld, details.shapeWithheld { return }
        entries[key] = details
    }

    /// Whether to fetch the verbose shape now; records the attempt, so an
    /// overlapping probe doesn't fetch it again.
    func claimShapeAttempt(for key: String, now: Date = Date()) -> Bool {
        if let last = shapeAttempts[key], now.timeIntervalSince(last) < Self.shapeRetryInterval { return false }
        shapeAttempts[key] = now
        return true
    }
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

    /// The server's version (`GET /api/version`).
    public func version(timeout: TimeInterval = 5) async throws -> String? {
        try await ProviderSupport.fetchJSON(http, HTTPRequest(url: try ProviderSupport.url(baseURL, "api/version"), timeout: timeout))["version"]?.stringValue
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
    /// When Ollama withholds the per-layer shape, `shapeWithheld` is set and
    /// `kvBytesPerToken` is nil; `shape(_:)` fetches it.
    public func show(_ model: String, timeout: TimeInterval = 10) async throws -> OllamaModelDetails {
        OllamaModelDetails.parse(try await showJSON(model, verbose: false, timeout: timeout))
    }

    /// The KV shape from verbose `/api/show` (several MB: it includes the
    /// tokenizer), for models whose normal response withholds it.
    func shape(_ model: String, timeout: TimeInterval) async throws -> (perToken: Int, fixed: Int)? {
        let verbose = OllamaModelDetails.parse(try await showJSON(model, verbose: true, timeout: timeout))
        return verbose.kvBytesPerToken.map { ($0, verbose.fixedKVBytes) }
    }

    private func showJSON(_ model: String, verbose: Bool, timeout: TimeInterval) async throws -> JSONValue {
        var body: [String: JSONValue] = ["model": .string(model)]
        if verbose { body["verbose"] = true }
        return try await ProviderSupport.fetchJSON(http, HTTPRequest.json(try ProviderSupport.url(baseURL, "api/show"), body: .object(body), timeout: timeout))
    }

    /// Details for every model, concurrently. Each digest is read once and
    /// cached; `timeout` bounds the normal `/api/show`, `shapeTimeout` the
    /// verbose shape fetch, which can fail without losing the capabilities.
    /// Models with no details at all are left out (callers fall back to what
    /// `/api/tags` reports, then to the name).
    public func details(for models: [OllamaModel], timeout: TimeInterval, shapeTimeout: TimeInterval = 5,
                        serverVersion: String? = nil) async -> [String: OllamaModelDetails] {
        // The server version is part of the key: an upgraded Ollama may report
        // more about the same digest (capabilities, templates).
        let base = "\(baseURL.absoluteString)|\(serverVersion ?? "")"
        return await withTaskGroup(of: (String, OllamaModelDetails?).self) { group in
            for model in models {
                group.addTask {
                    let key = "\(base)|\(model.name)|\(model.digest ?? "")"
                    var details = await OllamaDetailsCache.shared.details(for: key)
                    if details == nil {
                        details = await LocalModelDiscovery.withTimeout(timeout) { try await self.show(model.name, timeout: timeout) }
                    }
                    guard var found = details else { return (model.name, nil) }
                    if found.shapeWithheld, await OllamaDetailsCache.shared.claimShapeAttempt(for: key),
                       let shape = await LocalModelDiscovery.withTimeout(shapeTimeout, { try await self.shape(model.name, timeout: shapeTimeout) }) ?? nil {
                        found.kvBytesPerToken = shape.perToken
                        found.fixedKVBytes = shape.fixed
                        found.shapeWithheld = false
                    }
                    if model.digest != nil {
                        await OllamaDetailsCache.shared.store(found, for: key)
                        // An overlapping probe may have completed the shape meanwhile.
                        if let cached = await OllamaDetailsCache.shared.details(for: key), !cached.shapeWithheld { found = cached }
                    }
                    return (model.name, found)
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
        let details = await details(for: models, timeout: detailsTimeout, serverVersion: try? await version(timeout: detailsTimeout))
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
                digest: entry["digest"]?.stringValue,
                capabilities: entry["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                contextLength: details?["context_length"]?.intValue
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
        let reported = details.flatMap { $0.capabilities.isEmpty ? nil : $0.capabilities } ?? (model.capabilities.isEmpty ? nil : model.capabilities)
        if let reported, !reported.contains("completion") {
            // Embedding-only (bge-m3, all-minilm…) or other non-chat models
            // (image generation): never in the chat picker or a chat default.
            capabilities = reported.contains("embedding") ? [.embeddings] : []
        } else if let reported {
            if reported.contains("tools") {
                capabilities.insert(.tools)
                if let details {
                    if details.forcesToolCalls { capabilities.insert(.eagerToolCalls) }
                } else if (model.family ?? "").lowercased() == "llama" {
                    // Template unknown (only /api/tags answered): Llama 3.x
                    // templates force a call whenever tools are offered.
                    capabilities.insert(.eagerToolCalls)
                }
            }
            if reported.contains("vision") { capabilities.insert(.vision) }
            if reported.contains("thinking") { capabilities.insert(.reasoning) }
        } else if OllamaProvider.looksLikeEmbeddingModel(model) {
            capabilities = [.embeddings]
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
        let context = contextLength(for: model, details: details, physicalMemory: physicalMemory)
        var memory: Int64?
        if model.size > 0 {
            let kv = Int64(details?.kvBytesPerToken ?? 0) * Int64(context) + Int64(details?.fixedKVBytes ?? 0)
            memory = model.size + kv
        }
        return ModelInfo(id: model.name, providerID: providerID, displayName: displayName,
                         contextWindow: context, capabilities: capabilities, isLocal: true, memoryBytes: memory,
                         revision: model.digest)
    }

    /// Name and family guesses for servers too old to report capabilities.
    static func looksLikeEmbeddingModel(_ model: OllamaModel) -> Bool {
        let name = model.name.lowercased()
        let families = Set(([model.family].compactMap { $0 } + model.families).map { $0.lowercased() })
        return ["embed", "minilm", "bge-", "bge:", "e5-"].contains(where: name.contains) || !families.isDisjoint(with: ["bert", "nomic-bert"])
    }

    /// Context sizes Cove picks between (`num_ctx`). Larger windows cost
    /// memory up front, so this stops at 32K.
    static let contextSteps = [4_096, 8_192, 16_384, 32_768]

    /// The `num_ctx` Cove runs a model with: the largest step whose KV cache
    /// fits beside the weights in ~70% of RAM (about what macOS lets the GPU
    /// use), never more than the model was trained for. Sent with every
    /// request and used as the context budget, so the two always agree.
    static func contextLength(for model: OllamaModel, details: OllamaModelDetails?, physicalMemory: UInt64) -> Int {
        let trained = details?.contextLength ?? model.contextLength ?? KnownModels.contextWindow(for: model.name) ?? KnownModels.defaultLocalContextWindow
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
                        var entry: [String: JSONValue] = ["function": ["name": .string(call.name), "arguments": arguments]]
                        if !call.id.isEmpty { entry["id"] = .string(call.id) }
                        return .object(entry)
                    })
                }
                out.append(.object(entry))
            case .user, .tool:
                for result in message.toolResults {
                    var text = result.text
                    if result.isError && !text.hasPrefix("Error") { text = "Error: " + text }
                    var entry: [String: JSONValue] = ["role": "tool", "tool_name": .string(result.name), "content": .string(text)]
                    if !result.callID.isEmpty { entry["tool_call_id"] = .string(result.callID) }
                    out.append(.object(entry))
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
