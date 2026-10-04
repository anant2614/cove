import Foundation
import XCTest
import CoveProviders
@testable import CoveTools

final class GenerateImageToolTests: XCTestCase {
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])

    func testBase64PathSavesAttachment() async throws {
        let http = MockHTTPClient()
        http.on("/v1/images/generations", body: """
        {"created":1713833628,"data":[{"b64_json":"\(pngBytes.base64EncodedString())","revised_prompt":"A red fox, watercolor"}],
         "usage":{"total_tokens":100}}
        """)
        let sink = MockAttachmentSink()
        let tool = GenerateImageTool(http: http, apiKeyProvider: { "sk-test" })
        let result = try await tool.invoke(
            call("generate_image", ""),
            arguments: ["prompt": "A red fox in the snow!", "size": "1536x1024", "quality": "high"],
            context: ToolContext(chatID: "c", attachmentSink: sink)
        )

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.timeout, 120)
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(request.jsonBody, ["model": "gpt-image-1", "prompt": "A red fox in the snow!",
                                          "size": "1536x1024", "n": 1, "quality": "high"])

        XCTAssertEqual(sink.saved.count, 1)
        XCTAssertEqual(sink.saved[0].data, pngBytes)
        XCTAssertEqual(sink.saved[0].mime, "image/png")
        XCTAssertEqual(sink.saved[0].filename, "a-red-fox-in-the-snow.png")

        XCTAssertEqual(result.images, [ImageContent(mime: "image/png", attachmentID: "att-1")])
        XCTAssertNil(result.images.first?.data)
        XCTAssertEqual(result.text, "Generated an image for: A red fox in the snow!. It is shown to the user as an attachment.")
        XCTAssertEqual(result.metadata, ["attachmentID": "att-1", "revisedPrompt": "A red fox, watercolor"])
    }

    func testURLPathDownloadsImage() async throws {
        let http = MockHTTPClient()
        http.on("images/generations", body: #"{"data":[{"url":"https://cdn.example.com/img.png"}]}"#)
        http.on("cdn.example.com", data: pngBytes, headers: ["Content-Type": "image/png"])
        let sink = MockAttachmentSink()
        let tool = GenerateImageTool(http: http, apiKeyProvider: { "k" }, baseURL: URL(string: "https://proxy.local/v1"), model: "dall-e-3")
        let result = try await tool.invoke(call("generate_image", ""), arguments: ["prompt": "x"],
                                           context: ToolContext(chatID: "c", attachmentSink: sink))
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://proxy.local/v1/images/generations")
        XCTAssertEqual(http.requests.first?.jsonBody?["size"], "1024x1024")
        XCTAssertNil(http.requests.first?.jsonBody?["quality"])
        XCTAssertEqual(sink.saved.first?.data, pngBytes)
        XCTAssertEqual(result.metadata, ["attachmentID": "att-1"])
    }

    func testMissingSinkFailsBeforeNetwork() async {
        let http = MockHTTPClient()
        let result = await ToolRegistry([GenerateImageTool(http: http, apiKeyProvider: { "k" })])
            .invoke(call("generate_image", #"{"prompt":"cat"}"#), context: ToolContext(chatID: "c"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testInvalidSizeAndAPIError() async {
        let http = MockHTTPClient()
        http.on("images/generations", status: 400, body: #"{"error":{"message":"Your request was rejected by the safety system."}}"#)
        let registry = ToolRegistry([GenerateImageTool(http: http, apiKeyProvider: { "k" })])
        let ctx = ToolContext(chatID: "c", attachmentSink: MockAttachmentSink())

        let badSize = await registry.invoke(call("generate_image", #"{"prompt":"cat","size":"10x10"}"#), context: ctx)
        XCTAssertTrue(badSize.isError)
        XCTAssertTrue(badSize.text.contains("size"))

        let rejected = await registry.invoke(call("generate_image", #"{"prompt":"cat"}"#), context: ctx)
        XCTAssertTrue(rejected.isError)
        XCTAssertTrue(rejected.text.contains("400"))
        XCTAssertTrue(rejected.text.contains("safety system"))
    }

    func testAnnotationsPromptOnAskOnWrite() {
        let tool = GenerateImageTool(http: MockHTTPClient(), apiKeyProvider: { nil })
        XCTAssertTrue(tool.annotations.readOnly)
        XCTAssertTrue(tool.annotations.spendsOrSends)
        XCTAssertTrue(tool.annotations.requiresNetwork)
        XCTAssertTrue(tool.annotations.isWrite)
        XCTAssertEqual(GenerateImageTool.filename(for: "   !!! "), "generated-image.png")
    }

    func testBuiltinToolsFactory() {
        let http = MockHTTPClient()
        let all = BuiltinTools.make(http: http, webSearch: (kind: .brave, keyProvider: { "k" }), imageKeyProvider: { "k" }, imageBaseURL: nil)
        XCTAssertEqual(all.map(\.name), ["web_search", "fetch_url", "generate_image"])
        let minimal = BuiltinTools.make(http: http, webSearch: nil, imageKeyProvider: nil)
        XCTAssertEqual(minimal.map(\.name), ["fetch_url"])
    }
}
