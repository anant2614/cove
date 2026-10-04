#if os(macOS)
import AppKit
import SwiftUI

/// A collapsible record of one tool call and its result (T5 acceptance:
/// "the tool call is visible and collapsible in the chat").
public struct ToolCallView: View {
    public var call: ToolCall
    public var result: ToolResult?
    @State private var expanded = false

    public init(call: ToolCall, result: ToolResult?) {
        self.call = call
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    statusIcon
                    Text(Self.title(for: call)).font(.callout.weight(.medium))
                    if let summary = argumentSummary {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Self.title(for: call)), \(expanded ? "expanded" : "collapsed")")

            if !sources.isEmpty {
                SourcesRow(sources: sources)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arguments").font(.caption).foregroundStyle(.secondary)
                    Text(prettyArguments)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                    if let result {
                        Text(result.isError ? "Error" : "Result").font(.caption).foregroundStyle(result.isError ? .red : .secondary)
                        ScrollView {
                            Text(result.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder private var statusIcon: some View {
        if result == nil {
            ProgressView().controlSize(.small)
        } else if result?.isError == true {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: Self.icon(for: call.name)).foregroundStyle(.secondary)
        }
    }

    static func title(for call: ToolCall) -> String {
        switch call.name {
        case "web_search": "Searched the web"
        case "fetch_url": "Read a web page"
        case "generate_image": "Generated an image"
        default: "Used \(call.name)"
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "web_search": "magnifyingglass"
        case "fetch_url": "doc.text.magnifyingglass"
        case "generate_image": "photo"
        default: "wrench.and.screwdriver"
        }
    }

    private var argumentSummary: String? {
        guard let args = try? call.parsedArguments() else { return nil }
        return args["query"]?.stringValue ?? args["url"]?.stringValue ?? args["prompt"]?.stringValue
    }

    private var prettyArguments: String {
        (try? call.parsedArguments().jsonString(pretty: true)) ?? call.arguments
    }

    private var sources: [(title: String, url: URL)] {
        guard let list = result?.metadata?["sources"]?.arrayValue else { return [] }
        return list.compactMap { item in
            guard let raw = item["url"]?.stringValue, let url = URL(string: raw) else { return nil }
            return (item["title"]?.stringValue ?? url.host ?? raw, url)
        }
    }
}

struct SourcesRow: View {
    let sources: [(title: String, url: URL)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(sources.prefix(8).enumerated()), id: \.offset) { index, source in
                    Link(destination: source.url) {
                        HStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(source.url.host ?? source.title).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                    .help(source.title)
                }
            }
        }
    }
}
#endif
