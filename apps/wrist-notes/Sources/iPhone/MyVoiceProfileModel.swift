import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Main-actor commit point: cancellation, replacement and deletion invalidate pending enrollment.
@MainActor final class MyVoiceProfileModel: ObservableObject {
    @Published private(set) var profile: VoiceProfile?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var storageError: String?
    private let store: VoiceProfileStore
    private let enroll: (URL) async throws -> VoiceProfile
    private var generation = UUID()
    private var lifecycleObservation: AnyCancellable?

    init(store: VoiceProfileStore = VoiceProfileStore(), enroll: ((URL) async throws -> VoiceProfile)? = nil) {
        self.store = store
        let service = LocalTranscriptionService()
        self.enroll = enroll ?? { try await service.enrollVoice(fileURL: $0) }
        reload()
        #if os(iOS)
        lifecycleObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.reload() } }
        #endif
    }

    var label: String {
        if storageError != nil { return "声音档案暂时无法读取 · 请重试" }
        return profile == nil ? "未登记 · 让笔记认出我说的话" : "已登记 · 在录音中识别我的发言"
    }

    /// File protection may make a valid profile unavailable during background launch.
    /// Keep the last successfully loaded profile; an error does not mean enrollment was deleted.
    func reload() {
        guard !isSaving else { return }
        do { profile = try store.load(); storageError = nil }
        catch { storageError = String(format: NSLocalizedString("无法读取声音档案：%@", comment: ""), error.localizedDescription) }
    }

    func saveRecording(url: URL, duration: TimeInterval, confirmedSolo: Bool) async -> Bool {
        guard !isSaving, storageError == nil else { return false }
        guard duration.isFinite, duration >= 30, duration <= 60.5 else { errorMessage = VoiceEnrollmentError.duration.localizedDescription; return false }
        guard confirmedSolo else { errorMessage = VoiceEnrollmentError.soloConfirmation.localizedDescription; return false }
        generation = UUID(); let request = generation
        isSaving = true; errorMessage = nil
        defer { if request == generation { isSaving = false } }
        do {
            let candidate = try await enroll(url)
            try Task.checkCancellation()
            guard request == generation else { return false }
            try store.save(candidate)
            profile = candidate
            return true
        } catch {
            if request == generation, !(error is CancellationError) { errorMessage = error.localizedDescription }
            return false
        }
    }

    func cancelEnrollment() { generation = UUID(); isSaving = false }
    @discardableResult func delete() -> Bool {
        cancelEnrollment()
        do { try store.delete(); profile = nil; errorMessage = nil; storageError = nil; return true }
        catch { errorMessage = String(format: NSLocalizedString("无法删除声音档案：%@", comment: ""), error.localizedDescription); return false }
    }
}
