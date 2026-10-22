import Combine
import Foundation

@MainActor
final class AISettingsModel: ObservableObject {
    enum TestState: Equatable { case idle, testing, success, failure(String) }
    @Published var configuration: AIConfiguration {
        didSet { if configuration != oldValue { invalidateTest() } }
    }
    @Published var apiKey: String {
        didSet { if apiKey != oldValue { invalidateTest() } }
    }
    @Published private(set) var state: TestState = .idle
    private let settings: AppSettings
    private let test: (AIConfiguration, String) async throws -> Void
    private var testTask: Task<Void, Never>?
    private var generation = 0

    init(settings: AppSettings, test: @escaping (AIConfiguration, String) async throws -> Void = {
        try await CustomAISummarizer().testConnection(configuration: $0, apiKey: $1)
    }) {
        self.settings = settings
        self.test = test
        configuration = settings.ai
        do {
            apiKey = try settings.apiKey()
            if configuration.mode == .custom, !apiKey.isEmpty { state = .success }
        } catch {
            apiKey = ""
            state = .failure(error.localizedDescription)
        }
    }

    var canSave: Bool {
        switch configuration.mode {
        case .local: true
        case .custom: state == .success
        case .chatgpt: settings.chatGPT.canSave(modelID: configuration.chatGPTModel, accountID: configuration.chatGPTAccountID)
        }
    }

    func invalidateTest() {
        generation += 1
        testTask?.cancel()
        testTask = nil
        state = .idle
    }

    func startTest() {
        invalidateTest()
        let config: AIConfiguration
        do { config = try configuration.validated(apiKey: apiKey) }
        catch { state = .failure(error.localizedDescription); return }
        let key = apiKey
        let version = generation
        state = .testing
        testTask = Task { [weak self, test] in
            do {
                try await test(config, key)
                guard let self, self.generation == version, !Task.isCancelled else { return }
                self.state = .success
            } catch {
                guard let self, self.generation == version, !Task.isCancelled else { return }
                self.state = .failure(error.localizedDescription)
            }
        }
    }

    func save() throws {
        guard canSave else { throw AIServiceError.invalidConfiguration("请先测试当前配置，再保存。") }
        try settings.saveAI(configuration, apiKey: apiKey)
    }
}
