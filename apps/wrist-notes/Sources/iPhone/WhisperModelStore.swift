import CryptoKit
import Foundation

struct WhisperModelFile: Codable, Sendable {
    let path: String
    let url: URL
    let bytes: Int64
    let sha256: String?
    let gitSHA1: String?
}

/// Whisper's public interface remains stable while both model families share atomic installation.
struct WhisperModelStore: Sendable {
    typealias Download = LocalModelAssetStore.Download
    let assets: LocalModelAssetStore
    var root: URL { assets.root }
    var catalogURL: URL? { assets.catalogURL }
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WristNotes/Models", isDirectory: true),
         catalogURL: URL? = Bundle.main.url(forResource: "WhisperModels", withExtension: "json"),
         downloadFile: Download? = nil) {
        assets = LocalModelAssetStore(root: root, catalogURL: catalogURL, requiredPaths: [
            "tokenizer.json", "tokenizer_config.json", "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/weights/weight.bin"], downloadFile: downloadFile)
    }
    func folder(for size: TranscriptionConfiguration.WhisperSize) -> URL { assets.folder(for: size.rawValue) }
    func files(for size: TranscriptionConfiguration.WhisperSize) throws -> [WhisperModelFile] { try assets.files(for: size.rawValue) }
    func installed(_ size: TranscriptionConfiguration.WhisperSize) -> Bool { assets.installed(size.rawValue) }
    func validate(_ size: TranscriptionConfiguration.WhisperSize) throws { try assets.validate(size.rawValue) }
    func download(_ size: TranscriptionConfiguration.WhisperSize,
                  progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        try await assets.download(size.rawValue, progress: progress)
    }
}

/// Only downloads public model assets. Audio and notes are never sent to this service.
struct LocalModelAssetStore: Sendable {
    typealias Download = @Sendable (URLRequest, @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
    let root: URL
    let catalogURL: URL?
    let requiredPaths: [String]
    private let downloadFile: Download?
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WristNotes/Models", isDirectory: true),
         catalogURL: URL? = Bundle.main.url(forResource: "WhisperModels", withExtension: "json"),
         requiredPaths: [String], downloadFile: Download? = nil) {
        self.root = root; self.catalogURL = catalogURL; self.requiredPaths = requiredPaths; self.downloadFile = downloadFile
    }

    func folder(for size: String) -> URL { root.appendingPathComponent(size, isDirectory: true) }
    func files(for size: String) throws -> [WhisperModelFile] {
        guard let catalogURL else { throw TranscriptionResourceError.invalidFiles }
        let catalog = try JSONDecoder().decode([String: [WhisperModelFile]].self, from: Data(contentsOf: catalogURL))
        guard let files = catalog[size], !files.isEmpty,
              Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ $0.bytes > 0 && !$0.path.isEmpty && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") &&
                  $0.url.scheme == "https" && $0.url.host == "huggingface.co" && validChecksum($0) }) else {
            throw TranscriptionResourceError.invalidFiles
        }
        guard requiredPaths.allSatisfy({ path in files.contains { $0.path == path } }) else { throw TranscriptionResourceError.invalidFiles }
        return files
    }
    private func stamp(_ files: [WhisperModelFile]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(files)))
    }
    func installed(_ size: String) -> Bool {
        guard let files = try? files(for: size),
              let marker = try? Data(contentsOf: folder(for: size).appendingPathComponent("installed.manifest")),
              marker == (try? stamp(files)) else { return false }
        return files.allSatisfy { file in
            let url = folder(for: size).appendingPathComponent(file.path)
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return false }
            return info.isRegularFile == true && info.isSymbolicLink != true && Int64(info.fileSize ?? -1) == file.bytes
        }
    }
    func validate(_ size: String) throws {
        guard installed(size) else { throw TranscriptionResourceError.missing }
        for file in try files(for: size) {
            try Task.checkCancellation()
            try verify(folder(for: size).appendingPathComponent(file.path), file: file)
        }
    }
    func download(_ size: String,
                  progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        try await ModelInstallCoordinator.shared.run(root: key) {
            try await downloadSerially(size, progress: progress)
        }
    }

    private func downloadSerially(_ size: String,
                                  progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        try Task.checkCancellation()
        let files = try files(for: size)
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // The root coordinator guarantees these cannot belong to an active install.
        for abandoned in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where abandoned.lastPathComponent.hasPrefix(".download-") || abandoned.lastPathComponent.hasPrefix(".assembly-") {
            try manager.removeItem(at: abandoned)
        }
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        if (try? validate(size)) != nil {
            progress(.init(fraction: 1, completedBytes: total, totalBytes: total)); return
        }
        try Task.checkCancellation()
        // Only complete, verified blobs enter this persistent content-addressed cache.
        // Assembly can be discarded on cancellation without throwing away downloaded work.
        let cache = root.appendingPathComponent(".verified-cache", isDirectory: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".assembly-\(size)-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3_600
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let cached = cache.appendingPathComponent(cacheKey(file))
            var reusable = false
            if manager.fileExists(atPath: cached.path) {
                do { try verify(cached, file: file); reusable = true }
                catch {
                    try Task.checkCancellation()
                    try manager.removeItem(at: cached)
                }
            }
            if !reusable {
                let base = completed
                let report: @Sendable (Int64) -> Void = { written in
                    let done = min(total, base + min(written, file.bytes))
                    progress(.init(fraction: Double(done) / Double(total), completedBytes: done, totalBytes: total))
                }
                var request = URLRequest(url: file.url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (temporary, response): (URL, URLResponse)
                if let downloadFile { (temporary, response) = try await downloadFile(request, report) }
                else { (temporary, response) = try await session.download(for: request, delegate: ModelDownloadObserver(progress: report)) }
                defer { try? manager.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw TranscriptionResourceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try verify(temporary, file: file)
                try manager.moveItem(at: temporary, to: cached)
            }
            let destination = staging.appendingPathComponent(file.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Independent copies keep installed-file damage from corrupting the reusable cache.
            try manager.copyItem(at: cached, to: destination)
            completed += file.bytes
            progress(.init(fraction: Double(completed) / Double(total), completedBytes: completed, totalBytes: total))
        }
        try Task.checkCancellation()
        // Validate the assembled model before issuing its completion marker or replacing an installation.
        for file in files { try verify(staging.appendingPathComponent(file.path), file: file) }
        try Task.checkCancellation()
        try stamp(files).write(to: staging.appendingPathComponent("installed.manifest"), options: .atomic)
        let destination = folder(for: size)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: staging, to: destination)
        guard installed(size) else { throw TranscriptionResourceError.invalidFiles }
    }

    private func validChecksum(_ file: WhisperModelFile) -> Bool {
        guard let checksum = file.sha256 ?? file.gitSHA1 else { return false }
        return checksum.count == (file.sha256 != nil ? 64 : 40) &&
            checksum.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func cacheKey(_ file: WhisperModelFile) -> String {
        file.sha256.map { "sha256-" + $0 } ?? "gitsha1-" + file.gitSHA1!
    }

    private func verify(_ url: URL, file: WhisperModelFile) throws {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, Int64(size) == file.bytes else {
            throw TranscriptionResourceError.invalidFiles
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        sha1.update(data: Data("blob \(file.bytes)\0".utf8))
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            if file.sha256 != nil { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
        }
        let actual = file.sha256 != nil ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == (file.sha256 ?? file.gitSHA1) else { throw TranscriptionResourceError.invalidFiles }
    }
}

/// Actor isolation alone is reentrant across URLSession awaits. An explicit FIFO
/// permit spans the whole operation, including cache writes and final promotion.
private actor ModelInstallCoordinator {
    static let shared = ModelInstallCoordinator()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func run(root: String, operation: @Sendable () async throws -> Void) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await acquire(root: root, id: id)
        } onCancel: {
            Task { await self.cancelWaiter(root: root, id: id) }
        }
        defer { release(root: root) }
        try Task.checkCancellation()
        try await operation()
    }

    private func acquire(root: String, id: UUID) async throws {
        try Task.checkCancellation()
        if occupied.insert(root).inserted { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters[root, default: []].append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(root: String, id: UUID) {
        guard let index = waiters[root]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[root]?.remove(at: index) else { return }
        if waiters[root]?.isEmpty == true { waiters.removeValue(forKey: root) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(root: String) {
        guard var queued = waiters[root], !queued.isEmpty else {
            occupied.remove(root); return
        }
        let next = queued.removeFirst()
        if queued.isEmpty { waiters.removeValue(forKey: root) }
        else { waiters[root] = queued }
        next.continuation.resume()
    }
}

private final class ModelDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
