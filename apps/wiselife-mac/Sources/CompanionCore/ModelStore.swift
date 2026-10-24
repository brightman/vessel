import Foundation
import CryptoKit

public struct CatalogModel: Codable, Sendable, Identifiable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }
    public let id: String
    public let name: String
    public let revision: String
    public let license: String
    public let source: String
    public let acceptance: String
    public let files: [File]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var directoryName: String { id.replacingOccurrences(of: "/", with: "--") + "-" + revision }
    public static func bundled() throws -> [Self] {
        try JSONDecoder().decode([Self].self, from: Data(contentsOf: Bundle.module.url(forResource: "ModelCatalog", withExtension: "json")!))
    }
}

public struct DownloadProgress: Sendable {
    public enum Phase: Sendable, Equatable { case downloading, verifying, complete }
    public let fraction: Double
    public let bytes: Int64
    public let total: Int64
    public let phase: Phase
    public let fileName: String
    public init(fraction: Double, bytes: Int64, total: Int64, phase: Phase = .downloading, fileName: String = "") {
        self.fraction = fraction; self.bytes = bytes; self.total = total; self.phase = phase; self.fileName = fileName
    }
}

public protocol ModelFileFetcher: Sendable {
    func fetch(_ url: URL, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public struct HubModelFetcher: ModelFileFetcher {
    public init() {}
    public func fetch(_ url: URL, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await ModelDownload(destination: destination, expectedBytes: expectedBytes, progress: progress).download(url)
    }
}

public actor ModelStore {
    public let root: URL
    private let fetcher: any ModelFileFetcher
    private var downloading = false
    public init(root: URL? = nil, fetcher: any ModelFileFetcher = HubModelFetcher()) throws {
        self.fetcher = fetcher
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WiseLifeMacCompanion/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Incomplete staging directories are never treated as installed models.
        for file in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
    public func isInstalled(_ model: CatalogModel) -> Bool {
        let receipt = root.appendingPathComponent(model.directoryName).appendingPathComponent("verified.json")
        guard let data = try? Data(contentsOf: receipt), let saved = try? JSONDecoder().decode(CatalogModel.self, from: data) else { return false }
        return saved == model
    }
    public func availableBytes() -> Int64 {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }
    public func install(_ model: CatalogModel, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        guard !downloading else { throw ServiceError.busy }
        try Self.validate(model)
        if isInstalled(model) { return }
        guard availableBytes() > model.bytes + 512 * 1024 * 1024 else {
            throw ServiceError(507, "insufficient_storage", "可用空间不足，请清理磁盘后重试。")
        }
        downloading = true; defer { downloading = false }
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let base = completed
            let url = URL(string: "https://huggingface.co/\(model.id)/resolve/\(model.revision)/\(file.name)")!
            let destination = staging.appendingPathComponent(file.name)
            progress(.init(fraction: Double(base) / Double(model.bytes), bytes: base, total: model.bytes, fileName: file.name))
            try await fetcher.fetch(url, to: destination, expectedBytes: file.bytes) { bytes in
                let count = min(file.bytes, max(0, bytes))
                progress(.init(fraction: Double(base + count) / Double(model.bytes), bytes: base + count, total: model.bytes, fileName: file.name))
            }
            progress(.init(fraction: Double(base + file.bytes) / Double(model.bytes), bytes: base + file.bytes, total: model.bytes, phase: .verifying, fileName: file.name))
            try Self.verify(destination, file: file)
            completed += file.bytes
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent("verified.json"), options: [.atomic])
        let destination = root.appendingPathComponent(model.directoryName)
        // Installation is a single rename on the same volume, after every file verifies.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        progress(.init(fraction: 1, bytes: model.bytes, total: model.bytes, phase: .complete))
    }
    public func verifiedDirectory(_ model: CatalogModel) throws -> URL {
        try Self.validate(model)
        guard isInstalled(model) else { throw ServiceError.notReady }
        let directory = root.appendingPathComponent(model.directoryName)
        for file in model.files { try Self.verify(directory.appendingPathComponent(file.name), file: file) }
        return directory
    }
    public func remove(_ model: CatalogModel) throws {
        guard !downloading else { throw ServiceError.busy }
        try Self.validate(model)
        let path = root.appendingPathComponent(model.directoryName)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    private static func validate(_ model: CatalogModel) throws {
        guard model.revision.count == 40, model.revision.allSatisfy(\.isHexDigit), model.id.hasPrefix("mlx-community/"),
              model.id.split(separator: "/").count == 2, !model.id.contains(".."),
              !model.files.isEmpty, Set(model.files.map(\.name)).count == model.files.count,
              model.files.allSatisfy({ !$0.name.contains("/") && !$0.name.contains("..") && !$0.name.hasPrefix(".") && $0.bytes > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) })
        else { throw ServiceError(422, "invalid_catalog", "模型目录校验失败。") }
    }
    public static func verify(_ url: URL, file: CatalogModel.File) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == file.bytes else { throw integrityError }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == file.sha256 else { throw integrityError }
    }
    private static let integrityError = ServiceError(422, "model_integrity_failed", "模型文件不完整或校验不符，请删除后重新下载。")
}

/// Uses URLSession's disk-backed downloader: multi-gigabyte weights never enter a Data buffer.
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedBytes: Int64
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var lastProgress = Date.distantPast
    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.expectedBytes = expectedBytes; self.progress = progress
    }
    func download(_ url: URL) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 7200; config.timeoutIntervalForRequest = 60
                config.urlCache = nil; config.httpCookieStorage = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session; let task = session.downloadTask(with: url); self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel() })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") || host.hasSuffix(".xethub.hf.co")
        completionHandler(request.url?.scheme == "https" && allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel() }
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.2 || totalBytesWritten >= expectedBytes {
            lastProgress = now; progress(min(totalBytesWritten, expectedBytes))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError(502, "download_failed", "模型下载未完成，请检查网络后重试。") }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil; lock.unlock()
        continuation?.resume(with: result); session?.finishTasksAndInvalidate()
    }
}
