import Combine
import Foundation
import ImageIO
import UIKit
import Vision

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var moments: [PhotoMoment] = []
    @Published var errorMessage: String?
    private let openRepository: () throws -> PhotoRepository
    private var lifecycleObservation: AnyCancellable?
    private var repository: PhotoRepository?
    var storageIsAvailable: Bool { repository != nil }

    init(root: URL? = nil, openRepository: (() throws -> PhotoRepository)? = nil) {
        let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoMoments", isDirectory: true)
        self.openRepository = openRepository ?? { try PhotoRepository(root: directory) }
        lifecycleObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.reload() } }
        reload()
    }

    func reload() {
        do {
            let opened = try openRepository()
            repository = opened
            moments = opened.moments.sorted { $0.capturedAt > $1.capturedAt }
            errorMessage = nil
        } catch {
            repository = nil
            errorMessage = "无法打开本地照片：\(error.localizedDescription)"
        }
    }

    func imageURL(for attachment: PhotoAttachment) -> URL? {
        guard let repository else { return nil }
        return try? repository.imageURL(for: attachment)
    }

    @discardableResult
    func save(caption: String, photos: [PhotoImport]) throws -> PhotoMoment {
        guard let repository else { throw PhotoStorageError.invalidIndex }
        do {
            let moment = try repository.save(caption: caption, photos: photos)
            moments = repository.moments.sorted { $0.capturedAt > $1.capturedAt }
            errorMessage = nil
            return moment
        } catch {
            errorMessage = "保存照片失败：\(error.localizedDescription)"
            throw error
        }
    }

    func delete(_ id: UUID) {
        guard let repository else {
            errorMessage = "本地照片尚未打开，无法删除。"
            return
        }
        do {
            try repository.delete(id: id)
            moments = repository.moments.sorted { $0.capturedAt > $1.capturedAt }
            errorMessage = nil
        } catch {
            moments = repository.moments.sorted { $0.capturedAt > $1.capturedAt }
            errorMessage = "删除照片失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func setAddress(_ address: CaptureAddress, photoID: UUID, matching point: CaptureLocation) -> Bool {
        do {
            guard let repository else { return false }
            let saved = try repository.setAddress(address, photoID: photoID, matching: point)
            moments = repository.moments.sorted { $0.capturedAt > $1.capturedAt }
            return saved
        } catch { errorMessage = "地点地址未保存：\(error.localizedDescription)"; return false }
    }
}

enum PhotoImageProcessing {
    // Decode a bounded, orientation-corrected image; the durable copy is a metadata-free JPEG.
    static func prepare(_ data: Data) async throws -> Data {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard data.count <= 80 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_800,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
                throw PhotoStorageError.invalidImage
            }
            try Task.checkCancellation()
            return jpeg
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func recognize(_ data: Data) async throws -> String {
        let work = PhotoRecognitionWork(data: data)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try work.run()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { work.cancel() }
    }
}

// Vision runs synchronously on its own queue; the lock only coordinates cancellation.
private final class PhotoRecognitionWork: @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?

    init(data: Data) { self.data = data }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = request
        lock.unlock()
        active?.cancel()
    }

    func run() throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        lock.lock()
        let wasCancelled = cancelled
        self.request = request
        lock.unlock()
        guard !wasCancelled else { throw CancellationError() }
        try VNImageRequestHandler(data: data, options: [:]).perform([request])
        lock.lock()
        let isCancelled = cancelled
        self.request = nil
        lock.unlock()
        guard !isCancelled else { throw CancellationError() }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
