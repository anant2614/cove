import Foundation
@_exported import CoveModels

/// The single interface every model backend implements (§15). Adapters
/// convert between Cove's internal message format and each wire protocol.
public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    func listModels() async throws -> [ModelInfo]
    /// Streams a response. Cancelling the consuming task cancels the request.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

extension LLMProvider {
    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        throw ProviderError.unsupported("embeddings")
    }
}
