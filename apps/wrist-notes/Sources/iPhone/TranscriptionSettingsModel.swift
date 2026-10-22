import Combine
import Foundation

@MainActor struct TranscriptionResourceClient {
    var languages: () async throws -> [SpeechLanguage]
    var status: (TranscriptionConfiguration) async throws -> SpeechResourceState
    var download: (TranscriptionConfiguration, @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws -> Void
}

@MainActor final class TranscriptionSettingsModel: ObservableObject {
    @Published var configuration: TranscriptionConfiguration {
        didSet {
            if configuration.resourceID != oldValue.resourceID { scheduleRefresh() }
        }
    }
    @Published private(set) var state: SpeechResourceState = .checking
    @Published private(set) var languages: [SpeechLanguage] = []
    private let settings: AppSettings
    private let resources: TranscriptionResourceClient
    private var operation: Task<Void, Never>?
    private var generation = 0

    init(settings: AppSettings, resources: TranscriptionResourceClient) {
        self.settings = settings
        self.resources = resources
        configuration = settings.transcription
    }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }
    var canSave: Bool {
        guard state == .ready else { return false }
        return configuration.engine == .apple ? languages.contains { $0.id == configuration.appleLocale } : configuration.validWhisperLanguage
    }
    func cancel() {
        generation += 1
        operation?.cancel(); operation = nil
        state = .checking
    }
    func scheduleRefresh() {
        cancel()
        operation = Task { [weak self] in await self?.refresh() }
    }
    func refresh() async {
        if isDownloading { return }
        generation += 1
        let version = generation
        let config = configuration
        state = .checking
        do {
            let available = try await resources.languages()
            guard generation == version, !Task.isCancelled else { return }
            languages = available
            if config.engine == .apple && !available.contains(where: { $0.id == config.appleLocale }) {
                state = .unavailable(available.isEmpty ? TranscriptionResourceError.appleUnavailableMessage : "请选择这台 iPhone 支持的转写语言。")
                return
            }
            let status = try await resources.status(config)
            guard generation == version, !Task.isCancelled else { return }
            state = status
        } catch {
            guard generation == version, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
    func startDownload() {
        guard !isDownloading, state != .ready else { return }
        if configuration.engine == .apple && !languages.contains(where: { $0.id == configuration.appleLocale }) { return }
        cancel()
        let version = generation
        let config = configuration
        state = .downloading(.init(fraction: nil))
        operation = Task { [weak self, resources] in
            do {
                try await resources.download(config) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == version, self.isDownloading else { return }
                        self.state = .downloading(progress)
                    }
                }
                try Task.checkCancellation()
                let status = try await resources.status(config)
                guard let self, self.generation == version else { return }
                self.state = status == .ready ? .ready : .failed("下载结束，但资源尚未就绪，请重试。")
            } catch {
                guard let self, self.generation == version, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
    func save() throws {
        guard canSave else { throw TranscriptionResourceError.missing }
        try settings.saveTranscription(configuration)
    }
}
