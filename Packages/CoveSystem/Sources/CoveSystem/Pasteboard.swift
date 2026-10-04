#if os(macOS)
import AppKit

/// Helpers for the general pasteboard, used for `{{clipboard}}` and
/// paste-to-attach in the composer.
public enum Pasteboard {
    /// The plain-text contents of the general pasteboard, if any.
    public static func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Replaces the general pasteboard's contents with `string`.
    public static func setString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Image data from the general pasteboard, as PNG.
    ///
    /// PNG data is returned as-is; TIFF data (what most apps put on the
    /// pasteboard) is converted to PNG.
    /// - Returns: The image data and its MIME type (`image/png`), or `nil`.
    public static func imageData() -> (Data, String)? {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) {
            return (png, "image/png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        return nil
    }

    /// File URLs on the general pasteboard (e.g. files copied in Finder).
    public static func fileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}
#endif
