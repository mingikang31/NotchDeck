import AppKit
import UniformTypeIdentifiers

/// Turns files, pasteboard contents and screenshots into chat attachments.
nonisolated enum ChatAttachmentFactory {
    /// Long-edge cap: larger images cost more tokens without helping the model.
    static let maxImageEdge: CGFloat = 1568
    static let maxImageBytes = 4_500_000      // Claude's per-image limit is 5 MB
    static let maxPDFBytes = 20_000_000       // stays under the 32 MB request limit once base64-encoded
    static let maxTextBytes = 400_000

    enum AttachmentError: LocalizedError, Equatable {
        case unsupported(String)
        case tooLarge(String, limit: String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "\(name) isn't a supported attachment (images, PDFs and text files are)."
            case .tooLarge(let name, let limit): "\(name) is too large to attach (limit \(limit))."
            case .unreadable(let name): "Couldn't read \(name)."
            }
        }
    }

    static func make(from url: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())

        if type?.conforms(to: .pdf) == true {
            guard data.count <= maxPDFBytes else { throw AttachmentError.tooLarge(name, limit: "20 MB") }
            return ChatAttachment(name: name, kind: .pdf, mediaType: "application/pdf", data: data)
        }
        if type?.conforms(to: .image) == true {
            return try image(from: data, name: name)
        }
        if type?.conforms(to: .text) == true || looksLikeText(data) {
            guard data.count <= maxTextBytes else { throw AttachmentError.tooLarge(name, limit: "400 KB") }
            guard String(data: data, encoding: .utf8) != nil else { throw AttachmentError.unreadable(name) }
            return ChatAttachment(name: name, kind: .text, mediaType: "text/plain", data: data)
        }
        throw AttachmentError.unsupported(name)
    }

    /// Normalizes any image to PNG (or JPEG when PNG would be too big), downscaled to `maxImageEdge`.
    static func image(from data: Data, name: String) throws -> ChatAttachment {
        guard let source = NSBitmapImageRep(data: data)?.cgImage ?? NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AttachmentError.unreadable(name)
        }
        let scaled = downscaled(source)
        let rep = NSBitmapImageRep(cgImage: scaled)
        let baseName = (name as NSString).deletingPathExtension
        if let png = rep.representation(using: .png, properties: [:]), png.count <= maxImageBytes {
            return ChatAttachment(name: baseName + ".png", kind: .image, mediaType: "image/png", data: png)
        }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), jpeg.count <= maxImageBytes {
            return ChatAttachment(name: baseName + ".jpg", kind: .image, mediaType: "image/jpeg", data: jpeg)
        }
        throw AttachmentError.tooLarge(name, limit: "5 MB")
    }

    static func downscaled(_ image: CGImage) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > maxImageEdge else { return image }
        let scale = maxImageEdge / longEdge
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Small, NUL-free, UTF-8: treat unknown extensions (Makefile, .env.example, …) as text.
    private static func looksLikeText(_ data: Data) -> Bool {
        data.count <= maxTextBytes && !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    /// Attachments from a pasteboard: file URLs first, then image data. Nil if there's nothing to attach
    /// (plain text is left for the text field's own paste).
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> (attachments: [ChatAttachment], errors: [String])? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return collect(urls.map { url in Result { try make(from: url) } })
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: type) {
                return collect([Result { try image(from: data, name: "Pasted Image") }])
            }
        }
        return nil
    }

    static func collect(_ results: [Result<ChatAttachment, Error>]) -> (attachments: [ChatAttachment], errors: [String]) {
        var attachments: [ChatAttachment] = []
        var errors: [String] = []
        for result in results {
            switch result {
            case .success(let attachment): attachments.append(attachment)
            case .failure(let error): errors.append(error.localizedDescription)
            }
        }
        return (attachments, errors)
    }

    /// Runs the system's interactive screen-selection capture. Nil if the user pressed Escape.
    static func captureScreenSelection() async -> Data? {
        let url = FileManager.default.temporaryDirectory.appending(path: "NotchDeck-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
        return try? Data(contentsOf: url)
    }
}
