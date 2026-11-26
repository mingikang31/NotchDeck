import Foundation

/// A finished download shown in the Live Activities tab.
nonisolated struct DownloadItem: Identifiable, Equatable, Sendable {
    var url: URL
    var date: Date
    var byteCount: Int64?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Watches ~/Downloads with a kqueue-backed DispatchSource and reports files that finish arriving.
///
/// Browsers write to a temporary name (`.crdownload`, `.download`, `.part`, …) and rename it when
/// done, so a finished download shows up as a *new* name with a normal extension. A file is
/// reported once its size has stopped changing.
///
/// The first read of ~/Downloads asks for permission (Privacy & Security → Files & Folders).
final class DownloadsWatcher {
    nonisolated static let temporaryExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp", "opdownload", "filepart", "aria2", "td", "!ut",
    ]

    var onNewFile: ((DownloadItem) -> Void)?
    /// False when the folder can't be read (permission denied).
    private(set) var isReadable = true

    let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
    }

    /// Starts watching. Returns the most recent existing downloads (from the last day) to seed the list.
    /// The first read runs off the main thread: it blocks while macOS shows its permission prompt.
    @discardableResult
    func start(seedCount: Int = 3) async -> [DownloadItem] {
        guard source == nil else { return [] }
        let path = directory.path
        let listing = await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(atPath: path)).map(Set.init)
        }.value
        guard source == nil else { return [] }
        guard let names = listing else {
            isReadable = false
            return []
        }
        isReadable = true
        known = names

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return [] }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source

        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        return names.filter(Self.isFinishedDownload)
            .compactMap { item(named: $0) }
            .filter { $0.date > dayAgo }
            .sorted { $0.date > $1.date }
            .prefix(seedCount)
            .map { $0 }
    }

    func stop() {
        source?.cancel()
        source = nil
        scanTask?.cancel()
        scanTask = nil
    }

    /// Hidden files, browser temp files and Chrome's "Unconfirmed 123" placeholders don't count.
    nonisolated static func isFinishedDownload(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.hasPrefix("Unconfirmed ") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !temporaryExtensions.contains(ext)
    }

    // MARK: Scanning

    /// Coalesces the burst of events a single download produces.
    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.scan()
        }
    }

    private func scan() async {
        guard let names = currentNames() else { return }
        let added = names.subtracting(known).filter(Self.isFinishedDownload)
        known = names
        for name in added.sorted() {
            guard let first = item(named: name) else { continue }
            // Wait for the size to settle (a copy into the folder may still be writing).
            var previous = first.byteCount
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                guard let next = item(named: name) else { break }
                if next.byteCount == previous {
                    onNewFile?(next)
                    break
                }
                previous = next.byteCount
            }
        }
    }

    private func currentNames() -> Set<String>? {
        (try? fileManager.contentsOfDirectory(atPath: directory.path)).map(Set.init)
    }

    private func item(named name: String) -> DownloadItem? {
        let url = directory.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]) else { return nil }
        let size = values.isDirectory == true ? values.totalFileAllocatedSize.map(Int64.init) : values.fileSize.map(Int64.init)
        return DownloadItem(url: url, date: values.addedToDirectoryDate ?? values.contentModificationDate ?? Date(), byteCount: size)
    }
}
