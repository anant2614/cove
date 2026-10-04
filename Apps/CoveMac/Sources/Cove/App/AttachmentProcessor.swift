import AppKit
import CoveCore
import PDFKit
import UniformTypeIdentifiers

/// Turns dropped, pasted or picked files into staged attachments (C3):
/// images are kept as images; PDFs, text and code become text the model can
/// read. Originals are always stored in Attachments/.
enum AttachmentProcessor {
    static let maxTextCharacters = 400_000

    enum ProcessingError: LocalizedError {
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "Cove can't attach “\(name)”. Images, PDFs and text or code files are supported."
            case .unreadable(let name): "Couldn't read “\(name)”."
            }
        }
    }

    static func stage(fileURL url: URL, store: CoveStore) async throws -> StagedAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ProcessingError.unreadable(url.lastPathComponent) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return try await stage(data: data, type: type, filename: url.lastPathComponent, store: store)
    }

    static func stage(data: Data, type: UTType, filename: String, store: CoveStore) async throws -> StagedAttachment {
        let mime = type.preferredMIMEType ?? "application/octet-stream"
        if type.conforms(to: .image) {
            let (imageData, imageMime) = normalizedImage(data: data, type: type, mime: mime)
            let attachment = try await store.attachments.save(data: imageData, mime: imageMime, filename: filename)
            return StagedAttachment(attachment: attachment, part: .image(ImageContent(mime: imageMime, attachmentID: attachment.id)), previewData: imageData)
        }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(data: data) else { throw ProcessingError.unreadable(filename) }
            let text = String((document.string ?? "").prefix(maxTextCharacters))
            let attachment = try await store.attachments.save(data: data, mime: "application/pdf", filename: filename)
            return StagedAttachment(attachment: attachment, part: .file(FileContent(name: filename, mime: "application/pdf", text: text, attachmentID: attachment.id)))
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || looksLikeText(data) {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ProcessingError.unreadable(filename)
            }
            let textMime = mime == "application/octet-stream" ? "text/plain" : mime
            let attachment = try await store.attachments.save(data: data, mime: textMime, filename: filename)
            return StagedAttachment(attachment: attachment, part: .file(FileContent(name: filename, mime: textMime, text: String(text.prefix(maxTextCharacters)), attachmentID: attachment.id)))
        }
        throw ProcessingError.unsupported(filename)
    }

    /// Converts HEIC/TIFF etc. to PNG (or keeps JPEG/PNG/GIF/WebP), and caps
    /// the longest side at 2048 px so requests stay small.
    static func normalizedImage(data: Data, type: UTType, mime: String) -> (Data, String) {
        guard let image = NSImage(data: data), let rep = image.representations.first else { return (data, mime) }
        let pixels = max(rep.pixelsWide, rep.pixelsHigh)
        let passthrough: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        if pixels <= 2048 && passthrough.contains(mime) { return (data, mime) }
        let scale = pixels > 2048 ? 2048.0 / Double(pixels) : 1
        let size = NSSize(width: Double(rep.pixelsWide) * scale, height: Double(rep.pixelsHigh) * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (data, mime) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return (data, mime) }
        return (png, "image/png")
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(4_096)
        guard !sample.isEmpty, !sample.contains(0) else { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    static var importableTypes: [UTType] { [.image, .pdf, .plainText, .sourceCode, .json, .xml, .commaSeparatedText, .text, .data] }
}
