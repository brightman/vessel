import Foundation
import Speech

extension AppleSpeechReservationCoordinator {
    static let shared = AppleSpeechReservationCoordinator(backend: .init(
        maximumReservations: AssetInventory.maximumReservedLocales,
        reservedLocales: { await AssetInventory.reservedLocales.map(\.identifier) },
        reserve: { _ = try await AssetInventory.reserve(locale: Locale(identifier: $0)) },
        release: { await AssetInventory.release(reservedLocale: Locale(identifier: $0)) },
        preferredLocale: { UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "zh-CN" },
        resolveLocale: {
            await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: $0))?.identifier ?? $0
        }
    ))
}

struct AppleSpeechResources {
    func languages() async -> [SpeechLanguage] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map {
            SpeechLanguage(id: $0.identifier.replacingOccurrences(of: "_", with: "-"), title: TranscriptionConfiguration.appleLanguageName($0.identifier))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func status(locale: String) async -> SpeechResourceState {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            return .unavailable(TranscriptionResourceError.unsupported.localizedDescription)
        }
        let module = SpeechTranscriber(locale: resolved, preset: .transcription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            do {
                try await AppleSpeechReservationCoordinator.shared.withReservation(locale: resolved.identifier) {
                    guard await AssetInventory.status(forModules: [module]) == .installed else { throw TranscriptionResourceError.missing }
                }
                return .ready
            } catch TranscriptionResourceError.missing { return .missing }
            catch { return .unavailable(error.localizedDescription) }
        case .supported, .downloading: return .missing
        case .unsupported: return .unavailable(TranscriptionResourceError.unsupported.localizedDescription)
        @unknown default: return .unavailable("系统暂时无法确定语言资源状态。")
        }
    }
    func download(locale: String, progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw TranscriptionResourceError.unsupported
        }
        try await AppleSpeechReservationCoordinator.shared.withReservation(locale: resolved.identifier) {
            let module = SpeechTranscriber(locale: resolved, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observation = Task {
                    while !Task.isCancelled {
                        let p = request.progress
                        progress(.init(fraction: p.totalUnitCount > 0 ? p.fractionCompleted : nil))
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                defer { observation.cancel() }
                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                    try Task.checkCancellation()
                } onCancel: { request.progress.cancel() }
            }
            guard await AssetInventory.status(forModules: [module]) == .installed else { throw TranscriptionResourceError.downloadFailed }
        }
        progress(.init(fraction: 1))
    }
}
