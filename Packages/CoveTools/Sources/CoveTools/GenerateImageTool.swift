import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoveProviders

/// The `generate_image` built-in tool (T8): creates an image with an
/// OpenAI-compatible Images API and saves it as a chat attachment.
public struct GenerateImageTool: Tool {
    /// The default API base URL.
    // The literal is a valid URL; the fallback is unreachable.
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/")
    public static let defaultModel = "gpt-image-1"
    public static let name = "generate_image"
    public static let sizes = ["1024x1024", "1536x1024", "1024x1536", "auto"]
    public static let qualities = ["low", "medium", "high", "auto"]
    /// Image generation is slow; allow two minutes.
    public static let timeout: TimeInterval = 120

    public let baseURL: URL
    public let model: String
    private let apiKeyProvider: APIKeyProvider
    private let http: any HTTPClient

    /// - Parameters:
    ///   - http: Transport for all requests.
    ///   - apiKeyProvider: Reads the API key lazily (e.g. from the Keychain).
    ///   - baseURL: API base, e.g. `https://api.openai.com/v1`.
    ///   - model: Image model name.
    public init(http: any HTTPClient, apiKeyProvider: @escaping APIKeyProvider,
                baseURL: URL? = nil, model: String = GenerateImageTool.defaultModel) {
        self.http = http
        self.apiKeyProvider = apiKeyProvider
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.model = model
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Generate an image from a text description. Only use this when the user explicitly asks you to create, draw or generate an image; never for greetings or ordinary questions. The image is shown to the user as an attachment. "
                + "Write a detailed prompt describing subject, style, composition and lighting.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "A detailed description of the image to create."],
                    "size": [
                        "type": "string",
                        "enum": .array(Self.sizes.map { .string($0) }),
                        "default": "1024x1024",
                        "description": "Image size: square, landscape (1536x1024), portrait (1024x1536) or auto.",
                    ],
                    "quality": [
                        "type": "string",
                        "enum": .array(Self.qualities.map { .string($0) }),
                        "description": "Rendering quality; higher is slower and costs more.",
                    ],
                ],
                "required": ["prompt"],
            ]
        )
    }

    /// Read-only, but it spends money, so `askOnWrite` prompts for it.
    public var annotations: ToolAnnotations {
        ToolAnnotations(readOnly: true, spendsOrSends: true, requiresNetwork: true)
    }

    public func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let prompt = try arguments.requiredString("prompt")
        let size = arguments.optionalString("size") ?? "1024x1024"
        guard Self.sizes.contains(size) else {
            throw ToolError.invalidArguments("`size` must be one of \(Self.sizes.joined(separator: ", ")).")
        }
        let quality = arguments.optionalString("quality")
        if let quality, !Self.qualities.contains(quality) {
            throw ToolError.invalidArguments("`quality` must be one of \(Self.qualities.joined(separator: ", ")).")
        }
        // Check the sink before spending money on a generation we cannot save.
        guard let sink = context.attachmentSink else {
            throw ToolError.failed("Generated images cannot be saved in this context (no attachment storage is available).")
        }
        guard let key = await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ToolError.notConfigured("No API key is set for image generation. Ask the user to add an OpenAI API key in Settings.")
        }

        var body: [String: JSONValue] = [
            "model": .string(model), "prompt": .string(prompt), "size": .string(size), "n": 1,
        ]
        if let quality { body["quality"] = .string(quality) }
        let request = HTTPRequest.json(
            baseURL.appendingPathComponent("images").appendingPathComponent("generations"),
            body: .object(body),
            headers: ["Authorization": "Bearer \(key)"],
            timeout: Self.timeout
        )
        let (data, head) = try await http.data(for: request)
        guard head.isSuccess else {
            let detail = HTTPErrorText.message(from: data).map { ": \($0)" } ?? "."
            if head.statusCode == 401 || head.statusCode == 403 {
                throw ToolError.failed("The image API key was rejected (HTTP \(head.statusCode))\(detail)")
            }
            throw ToolError.failed("Image generation failed with HTTP status \(head.statusCode)\(detail)")
        }
        guard let json = try? JSONValue.parse(data), let first = json["data"]?[0] else {
            throw ToolError.failed("The image API returned a response without image data.")
        }

        let (imageData, mime) = try await imageBytes(from: first)
        let attachment = try await sink.saveAttachment(data: imageData, mime: mime, filename: Self.filename(for: prompt, mime: mime))

        var metadata: [String: JSONValue] = ["attachmentID": .string(attachment.id)]
        if let revised = first["revised_prompt"]?.stringValue, !revised.isEmpty {
            metadata["revisedPrompt"] = .string(revised)
        }
        return ToolResult(
            callID: call.id,
            name: call.name,
            text: "Generated an image for: \(prompt). It is shown to the user as an attachment.",
            images: [ImageContent(mime: mime, attachmentID: attachment.id)],
            metadata: .object(metadata)
        )
    }

    /// Image bytes from `b64_json`, or downloaded from `url`.
    private func imageBytes(from item: JSONValue) async throws -> (Data, String) {
        if let b64 = item["b64_json"]?.stringValue {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                throw ToolError.failed("The image API returned invalid base64 image data.")
            }
            return (data, "image/png")
        }
        if let link = item["url"]?.stringValue, let url = URL(string: link) {
            let (data, head) = try await http.data(for: HTTPRequest(url: url, timeout: Self.timeout))
            guard head.isSuccess, !data.isEmpty else {
                throw ToolError.failed("Downloading the generated image failed with HTTP status \(head.statusCode).")
            }
            let type = head.header("Content-Type")?.split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            return (data, type.flatMap { $0.hasPrefix("image/") ? $0 : nil } ?? "image/png")
        }
        throw ToolError.failed("The image API returned a response without image data.")
    }

    /// A filesystem-friendly name derived from the prompt, e.g.
    /// `a-red-fox-in-the-snow.png`.
    static func filename(for prompt: String, mime: String = "image/png") -> String {
        let ext = switch mime {
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: "png"
        }
        var slug = ""
        var lastWasDash = false
        for scalar in prompt.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug += "-"
                lastWasDash = true
            }
            if slug.count >= 48 { break }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "generated-image" : slug) + ".\(ext)"
    }
}
