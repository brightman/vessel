import Foundation
import Speech

private struct AppleSpeechResourceModule: Sendable {
    let locale: Locale
    let module: any SpeechModule
}

extension AppleSpeechReservationCoordinator {
    static let shared = AppleSpeechReservationCoordinator(backend: .init(
        maximumReservations: AssetInventory.maximumReservedLocales,
        reservedLocales: { await AssetInventory.reservedLocales.map(\.identifier) },
        reserve: { _ = try await AssetInventory.reserve(locale: Locale(identifier: $0)) },
        release: { await AssetInventory.release(reservedLocale: Locale(identifier: $0)) },
        preferredLocale: { UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "zh-CN" },
        resolveLocale: { identifier in
            let requested = Locale(identifier: identifier)
            if SpeechTranscriber.isAvailable,
               let speech = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                return speech.identifier
            }
            if let dictation = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                return dictation.identifier
            }
            return identifier
        }
    ))
}

struct AppleSpeechResources {
    func languages() async -> [SpeechLanguage] {
        var byIdentifier: [String: SpeechLanguage] = [:]
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                let language = Self.language(locale)
                byIdentifier[language.id.lowercased()] = language
            }
        }
        for locale in await DictationTranscriber.supportedLocales {
            let language = Self.language(locale)
            let key = language.id.lowercased()
            if byIdentifier[key] == nil { byIdentifier[key] = language }
        }
        return byIdentifier.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func status(locale: String) async -> SpeechResourceState {
        let modules = await resourceModules(locale: Locale(identifier: locale))
        guard let first = modules.first else {
            return .unavailable(TranscriptionResourceError.unsupported.localizedDescription)
        }
        do {
            let statuses = try await AppleSpeechReservationCoordinator.shared.withReservation(locale: first.locale.identifier) {
                var values: [AssetInventory.Status] = []
                for module in modules {
                    values.append(await AssetInventory.status(forModules: [module.module]))
                }
                return values.map { status in
                    switch status {
                    case .unsupported: 0
                    case .supported: 1
                    case .downloading: 2
                    case .installed: 3
                    @unknown default: 0
                    }
                }
            }
            if statuses.contains(1) || statuses.contains(2) { return .missing }
            if statuses.contains(3) { return .ready }
            return .unavailable(TranscriptionResourceError.unsupported.localizedDescription)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func download(locale: String, progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        let modules = await resourceModules(locale: Locale(identifier: locale))
        guard let first = modules.first else { throw TranscriptionResourceError.unsupported }
        try await AppleSpeechReservationCoordinator.shared.withReservation(locale: first.locale.identifier) {
            let total = max(1, modules.count)
            for (index, module) in modules.enumerated() {
                try Task.checkCancellation()
                let initial = await AssetInventory.status(forModules: [module.module])
                guard initial != .installed else {
                    progress(.init(fraction: Double(index + 1) / Double(total)))
                    continue
                }
                guard initial != .unsupported else { continue }
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) else {
                    continue
                }
                let currentIndex = index
                let observation = Task {
                    while !Task.isCancelled {
                        let value = request.progress
                        let local = value.totalUnitCount > 0 ? value.fractionCompleted : nil
                        let combined = local.map { (Double(currentIndex) + $0) / Double(total) }
                        progress(.init(fraction: combined))
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                defer { observation.cancel() }
                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                    try Task.checkCancellation()
                } onCancel: {
                    request.progress.cancel()
                }
                guard await AssetInventory.status(forModules: [module.module]) == .installed else {
                    throw TranscriptionResourceError.downloadFailed
                }
                progress(.init(fraction: Double(index + 1) / Double(total)))
            }
        }
        guard await status(locale: locale) == .ready else { throw TranscriptionResourceError.downloadFailed }
        progress(.init(fraction: 1))
    }

    private func resourceModules(locale: Locale) async -> [AppleSpeechResourceModule] {
        var modules: [AppleSpeechResourceModule] = []
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            modules.append(.init(locale: supported,
                module: SpeechTranscriber(locale: supported, preset: .transcription)))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            modules.append(.init(locale: supported,
                module: DictationTranscriber(locale: supported, preset: .timeIndexedLongDictation)))
        }
        return modules
    }

    private static func language(_ locale: Locale) -> SpeechLanguage {
        SpeechLanguage(id: locale.identifier.replacingOccurrences(of: "_", with: "-"),
                       title: TranscriptionConfiguration.appleLanguageName(locale.identifier))
    }
}
