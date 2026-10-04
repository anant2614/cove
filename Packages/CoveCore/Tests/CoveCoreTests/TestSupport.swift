import XCTest
import Foundation
@testable import CoveCore

/// Emits scripted `ChatEvent` sequences, one script per call to `stream`.
final class MockProvider: LLMProvider, @unchecked Sendable {
    enum Step {
        case events([ChatEvent])
        /// Emits the events, then throws.
        case failing([ChatEvent], Error)
        /// Emits the events, then waits until cancelled.
        case hanging([ChatEvent])
    }

    let id: ProviderID
    let capabilities: ProviderCapabilities
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [ChatRequest] = []

    init(id: ProviderID = "mock", capabilities: ProviderCapabilities = .standard, steps: [Step]) {
        self.id = id
        self.capabilities = capabilities
        self.steps = steps
    }

    func listModels() async throws -> [ModelInfo] { [ModelInfo(id: "m", providerID: id)] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let step: Step = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? .events([.textDelta("(no script)"), .finished(.stop)]) : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch step {
                case .events(let events):
                    events.forEach { continuation.yield($0) }
                    continuation.finish()
                case .failing(let events, let error):
                    events.forEach { continuation.yield($0) }
                    continuation.finish(throwing: error)
                case .hanging(let events):
                    events.forEach { continuation.yield($0) }
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var requestCount: Int { lock.withLock { requests.count } }
    func request(_ index: Int) -> ChatRequest { lock.withLock { requests[index] } }
}

struct MockResolver: ProviderResolving {
    var providers: [ProviderID: any LLMProvider]
    var localIDs: Set<ProviderID> = []
    var window = 128_000
    var fallback: ModelRef?
    var infos: [ModelRef: ModelInfo] = [:]

    func provider(for model: ModelRef) async throws -> any LLMProvider {
        guard let provider = providers[model.providerID] else { throw ProviderError.unsupported("unknown provider") }
        return provider
    }
    func isLocal(_ providerID: ProviderID) async -> Bool { localIDs.contains(providerID) }
    func contextWindow(for model: ModelRef) async -> Int { window }
    func fallbackLocalModel() async -> ModelRef? { fallback }
    func modelInfo(for model: ModelRef) async -> ModelInfo? { infos[model] }
}

/// A tool that echoes its arguments.
struct EchoTool: Tool {
    var name_ = "echo"
    var annotations: ToolAnnotations = ToolAnnotations(readOnly: true)
    var spec: ToolSpec {
        ToolSpec(name: name_, description: "Echo", inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]])
    }
    func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, name: call.name, text: "echo: \(arguments["text"]?.stringValue ?? "")")
    }
}

/// Records approval prompts and answers with a fixed decision.
actor RecordingApprover: ApprovalRequester {
    let decision: ApprovalDecision
    private(set) var requests: [ApprovalRequest] = []
    init(_ decision: ApprovalDecision) { self.decision = decision }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return decision
    }
}

func collect(_ stream: AsyncThrowingStream<EngineEvent, Error>) async -> (events: [EngineEvent], error: Error?) {
    var events: [EngineEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

extension Array where Element == EngineEvent {
    var text: String {
        compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
    }
    var finishReason: FinishReason? {
        compactMap { if case .finished(let r) = $0 { r } else { nil } }.last
    }
    var savedMessages: [Message] {
        compactMap { if case .messageSaved(let m) = $0 { m } else { nil } }
    }
}

func head(_ store: InMemoryConversationStore, _ chatID: String) async throws -> String {
    let head = await store.chat(id: chatID)?.headMessageID
    return try XCTUnwrap(head)
}
