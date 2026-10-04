import Foundation

/// Thread-safe catalog of the tools available to the conversation engine.
///
/// Built-in and MCP tools are registered here under their spec name. The
/// registry produces the `ToolSpec` list offered to the model (respecting the
/// per-chat enabled set and connectivity) and runs tool calls, converting every
/// failure into an error `ToolResult` so a bad call never aborts a turn.
public final class ToolRegistry: @unchecked Sendable {
    // `@unchecked` is sound: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var tools: [String: any Tool] = [:]
    /// Registration order, so spec lists are stable across calls.
    private var order: [String] = []

    /// Creates a registry, optionally pre-populated with `tools`.
    public init(_ tools: [any Tool] = []) {
        for tool in tools { register(tool) }
    }

    /// Adds `tool`, replacing any existing tool with the same name (keeping its
    /// position in the list).
    public func register(_ tool: any Tool) {
        lock.withLock {
            let name = tool.name
            if tools[name] == nil { order.append(name) }
            tools[name] = tool
        }
    }

    /// Removes the tool called `name`, if present.
    public func unregister(name: String) {
        lock.withLock {
            guard tools.removeValue(forKey: name) != nil else { return }
            order.removeAll { $0 == name }
        }
    }

    /// The tool registered under `name`.
    public func tool(named name: String) -> (any Tool)? {
        lock.withLock { tools[name] }
    }

    /// All registered tools in registration order.
    public var allTools: [any Tool] {
        lock.withLock { order.compactMap { tools[$0] } }
    }

    /// Specs to offer the model.
    ///
    /// - Parameters:
    ///   - enabled: Names of tools enabled for the chat; `nil` means all.
    ///   - isOnline: When `false`, tools that require the network are left out.
    public func specs(enabled: Set<String>?, isOnline: Bool) -> [ToolSpec] {
        candidates(enabled: enabled)
            .filter { isOnline || !$0.annotations.requiresNetwork }
            .map(\.spec)
    }

    /// A sentence for the system prompt naming enabled tools that are
    /// unavailable because the Mac is offline (PRD §18), or `nil` when nothing
    /// is affected.
    public func offlineNotice(enabled: Set<String>?, isOnline: Bool) -> String? {
        guard !isOnline else { return nil }
        let unavailable = candidates(enabled: enabled)
            .filter { $0.annotations.requiresNetwork }
            .map(\.name)
        guard !unavailable.isEmpty else { return nil }
        let list = unavailable.map { "`\($0)`" }.joined(separator: ", ")
        let noun = unavailable.count == 1 ? "tool is" : "tools are"
        return "The Mac is currently offline, so the following \(noun) unavailable: \(list). "
            + "If the user asks for something that needs them, explain that it requires an internet connection."
    }

    /// Runs `call`. Never throws: unknown tools, malformed arguments, offline
    /// network tools and errors thrown by the tool all become error results.
    public func invoke(_ call: ToolCall, context: ToolContext) async -> ToolResult {
        func failure(_ message: String) -> ToolResult {
            ToolResult(callID: call.id, name: call.name, text: message, isError: true)
        }

        guard let tool = tool(named: call.name) else {
            let known = allTools.map(\.name).sorted()
            let hint = known.isEmpty ? "No tools are available." : "Available tools: \(known.joined(separator: ", "))."
            return failure("Unknown tool `\(call.name)`. \(hint)")
        }
        if !context.isOnline && tool.annotations.requiresNetwork {
            return failure(ToolError.unavailableOffline.localizedDescription)
        }

        let arguments: JSONValue
        do {
            arguments = try call.parsedArguments()
        } catch {
            return failure("Invalid arguments: the arguments for `\(call.name)` are not valid JSON. Retry with a JSON object matching the tool's schema.")
        }
        guard arguments.objectValue != nil else {
            return failure("Invalid arguments: the arguments for `\(call.name)` must be a JSON object.")
        }

        do {
            var result = try await tool.invoke(call, arguments: arguments, context: context)
            // Tie the result to the call even if a tool forgot to.
            result.callID = call.id
            result.name = call.name
            return result
        } catch let error as ToolError {
            return failure(error.localizedDescription)
        } catch is CancellationError {
            return failure("The tool call was cancelled.")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return failure("`\(call.name)` failed: \(description)")
        }
    }

    private func candidates(enabled: Set<String>?) -> [any Tool] {
        let all = allTools
        guard let enabled else { return all }
        return all.filter { enabled.contains($0.name) }
    }
}
