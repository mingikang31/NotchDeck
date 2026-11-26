import AppKit
import Observation
import OSLog
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One shelf entry: either a reference to a file elsewhere (bookmark, survives moves/renames)
/// or a staged copy NotchDeck owns (dropped text/images, zips).
nonisolated struct TrayItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var displayName: String
    /// Bookmark to the original file (referenced items).
    var bookmark: Data?
    /// File name inside the staging directory (staged items).
    var stagedFileName: String?
    var byteCount: Int64?
    var addedAt = Date()

    var isStaged: Bool { stagedFileName != nil }
}

/// Drag-and-drop shelf: drop in, drag out, AirDrop, zip, clear.
/// Persists to `~/Library/Application Support/NotchDeck/tray.json`; staged files live in `…/Tray/`.
@Observable
final class FileTrayStore {
    private(set) var items: [TrayItem] = []
    var selection: Set<TrayItem.ID> = []
    private(set) var thumbnails: [TrayItem.ID: NSImage] = [:]
    private(set) var isZipping = false
    private(set) var lastError: String?
    /// True while a drag hovers anywhere over the notch (drives the "Release to add" highlight).
    var isDropTargeted = false

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchdeck.NotchDeck", category: "FileTray")

    var stagingDirectory: URL { directory.appending(path: "Tray", directoryHint: .isDirectory) }
    private var indexURL: URL { directory.appending(path: "tray.json") }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "NotchDeck", directoryHint: .isDirectory)
    }

    init(directory: URL = FileTrayStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        load()
    }

    // MARK: Resolution

    func url(for item: TrayItem) -> URL? {
        if let name = item.stagedFileName {
            let url = stagingDirectory.appending(path: name)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        guard let bookmark = item.bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &isStale),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Items whose files still exist.
    var availableItems: [TrayItem] { items.filter { url(for: $0) != nil } }

    /// The selection if any, otherwise everything: what tray actions apply to.
    var actionTargets: [TrayItem] {
        let available = availableItems
        let selected = available.filter { selection.contains($0.id) }
        return selected.isEmpty ? available : selected
    }

    // MARK: Adding

    func add(fileURLs: [URL]) {
        var existing = Set(items.compactMap { url(for: $0)?.standardizedFileURL.path })
        var added = false
        for url in fileURLs where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !existing.contains(path), let bookmark = try? url.bookmarkData() else { continue }
            existing.insert(path)
            items.append(TrayItem(displayName: url.lastPathComponent, bookmark: bookmark, byteCount: Self.size(of: url, using: fileManager)))
            added = true
        }
        if added { didChange() }
    }

    /// Stages raw text (e.g. a dragged text selection or web link) as a .txt file.
    func add(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stage(Data(text.utf8), suggestedName: "Text \(Self.timestamp()).txt")
    }

    /// Stages dropped image data (screenshots, browser images).
    func add(imageData: Data, fileExtension: String) {
        stage(imageData, suggestedName: "Image \(Self.timestamp()).\(fileExtension)")
    }

    /// Pasteboard types the notch accepts as a drop.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, NSPasteboard.PasteboardType("public.jpeg"), .tiff, .URL, .string,
    ]

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(where: pasteboardTypes.contains) ?? false
    }

    /// Takes whatever was dropped, in order of preference: files, images, web links, text.
    /// Reads the pasteboard synchronously, so the tray updates the moment the drop lands.
    @discardableResult
    func handleDrop(pasteboard: NSPasteboard) -> Bool {
        lastError = nil
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(fileURLs: urls)
            return true
        }
        let images: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (.tiff, "tiff")]
        for (type, ext) in images {
            guard let data = pasteboard.data(forType: type) else { continue }
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                add(imageData: png, fileExtension: "png") // TIFF from browsers is huge; store PNG
            } else {
                add(imageData: data, fileExtension: ext)
            }
            return true
        }
        if let links = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !links.isEmpty {
            add(text: links.map(\.absoluteString).joined(separator: "\n"))
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            add(text: text)
            return true
        }
        logger.notice("Drop had no supported types: \(String(describing: pasteboard.types), privacy: .public)")
        return false
    }

    // MARK: Removing

    func remove(_ ids: Set<TrayItem.ID>) {
        for item in items where ids.contains(item.id) {
            if let name = item.stagedFileName {
                try? fileManager.removeItem(at: stagingDirectory.appending(path: name))
            }
            thumbnails[item.id] = nil
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        didChange()
    }

    func clearAll() {
        remove(Set(items.map(\.id)))
    }

    /// Drops entries whose referenced file has disappeared.
    func pruneMissing() {
        let missing = Set(items.filter { url(for: $0) == nil }.map(\.id))
        if !missing.isEmpty { remove(missing) }
    }

    func toggleSelection(_ id: TrayItem.ID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Actions

    var canAirDrop: Bool {
        NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: actionTargets.compactMap(url(for:))) ?? false
    }

    func airDrop() {
        let urls = actionTargets.compactMap(url(for:))
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            lastError = "AirDrop isn't available right now."
            return
        }
        lastError = nil
        service.perform(withItems: urls)
    }

    /// Compresses the action targets into one staged .zip (Finder-compatible archive).
    func zipTargets() async {
        let urls = actionTargets.compactMap(url(for:))
        guard !urls.isEmpty else { return }
        isZipping = true
        lastError = nil
        defer { isZipping = false }

        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "NotchDeck Archive \(Self.timestamp())"
        let staging = stagingDirectory
        do {
            let zipURL = try await Task.detached(priority: .userInitiated) {
                try Self.makeZip(of: urls, named: name, into: staging)
            }.value
            let item = TrayItem(displayName: zipURL.lastPathComponent, stagedFileName: zipURL.lastPathComponent, byteCount: Self.size(of: zipURL, using: .default))
            items.append(item)
            selection = [item.id]
            didChange()
        } catch {
            lastError = "Couldn't create the archive: \(error.localizedDescription)"
        }
    }

    /// Archives with `ditto`, the same archiver Finder's "Compress" uses (keeps resource forks
    /// in __MACOSX, which other platforms ignore). One file → `name.zip` containing that file;
    /// several → `name.zip` containing a `name/` folder.
    nonisolated static func makeZip(of urls: [URL], named name: String, into stagingDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let workDirectory = fm.temporaryDirectory.appending(path: "NotchDeck-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: workDirectory) }

        let source: URL
        if urls.count == 1 {
            source = urls[0]
        } else {
            source = workDirectory.appending(path: name, directoryHint: .isDirectory)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            for url in urls {
                try fm.copyItem(at: url, to: uniqueURL(in: source, name: url.lastPathComponent, using: fm))
            }
        }

        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = uniqueURL(in: stagingDirectory, name: "\(name).zip", using: fm)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // --keepParent stores the folder itself (multi-file); a lone file is stored at the root.
        process.arguments = ["-c", "-k", "--sequesterRsrc"] + (urls.count == 1 ? [] : ["--keepParent"]) + [source.path, destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "NotchDeck.Zip", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "ditto failed" : message])
        }
        return destination
    }

    // MARK: Thumbnails

    func loadThumbnail(for item: TrayItem) {
        guard thumbnails[item.id] == nil, let url = url(for: item) else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 56, height: 56), scale: 2, representationTypes: .all
        )
        let id = item.id
        Task {
            let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            thumbnails[id] = image ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    // MARK: Persistence

    private func stage(_ data: Data, suggestedName: String) {
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let url = Self.uniqueURL(in: stagingDirectory, name: suggestedName, using: fileManager)
            try data.write(to: url, options: .atomic)
            items.append(TrayItem(displayName: url.lastPathComponent, stagedFileName: url.lastPathComponent, byteCount: Int64(data.count)))
            didChange()
        } catch {
            lastError = "Couldn't save the dropped item: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([TrayItem].self, from: data) else { return }
        items = stored
    }

    private func didChange() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        } catch {
            logger.error("Saving tray failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func uniqueURL(in directory: URL, name: String, using fm: FileManager) -> URL {
        var candidate = directory.appending(path: name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    nonisolated private static func size(of url: URL, using fm: FileManager) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]) {
            if values.isDirectory == true { return nil }
            return Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        }
        return nil
    }

    private static func timestamp() -> String {
        Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
    }
}
