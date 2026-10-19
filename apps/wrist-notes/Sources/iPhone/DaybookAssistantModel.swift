import Combine
import Foundation

@MainActor
final class DaybookAssistantModel: ObservableObject {
    struct Answer: Identifiable {
        let id = UUID()
        let question: String
        let text: String
        let generated: Bool
        let provider: String
    }

    struct RemoteConfirmation: Identifiable {
        let id = UUID()
        let question: String
        let context: String
        let sourceCount: Int
        let destination: String
        fileprivate let prepared: DaybookRetrieval.Prepared
        fileprivate let configuration: AIConfiguration
    }

    @Published private(set) var answer: Answer?
    @Published private(set) var prepared: DaybookRetrieval.Prepared?
    @Published private(set) var remoteConfirmation: RemoteConfirmation?
    @Published private(set) var isPending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?

    private var task: Task<Void, Never>?
    private var version = UUID()
    private var latestRecords: [DayRecord] = []
    private var latestDate: Date?
    private var latestAllowedKinds: Set<DayRecord.Kind> = [.voice, .thought, .image]
    private var latestConfiguration: AIConfiguration?
    private let answerService: any DaybookAnswering

    init(answerService: (any DaybookAnswering)? = nil) {
        self.answerService = answerService ?? DaybookAnswerService()
    }

    func synchronize(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, configuration: AIConfiguration) {
        let dayChanged = latestDate.map { !Calendar.current.isDate($0, inSameDayAs: selectedDate) } ?? false
        let configurationChanged = latestConfiguration.map { $0 != configuration } ?? false
        let sourcesChanged = prepared.map { !$0.isCurrent(records: records, allowedKinds: allowedKinds) } ?? false
        latestRecords = records; latestDate = selectedDate; latestAllowedKinds = allowedKinds
        latestConfiguration = configuration
        if prepared != nil && (dayChanged || configurationChanged || sourcesChanged) {
            invalidate()
            statusMessage = "日期、记录或读取权限已变化，旧回答已清除。请重新提问。"
        }
    }

    func ask(_ question: String, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings) {
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai)
        invalidate()
        do {
            let evidence = try DaybookRetrieval().prepare(question: question, records: records, selectedDate: selectedDate,
                                                        allowedKinds: allowedKinds)
            prepared = evidence
            if let direct = evidence.directResponse {
                answer = Answer(question: evidence.question, text: direct, generated: false, provider: "本地检索与统计")
            } else if settings.ai.mode == .custom {
                let host = URLComponents(string: settings.ai.baseURL)?.host ?? "已配置的模型服务"
                remoteConfirmation = RemoteConfirmation(question: evidence.question, context: evidence.context,
                                                        sourceCount: evidence.sources.count,
                                                        destination: "\(settings.ai.model) · \(host)",
                                                        prepared: evidence, configuration: settings.ai)
            } else {
                start(evidence, configuration: settings.ai, apiKey: nil)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmRemote(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings) {
        guard let confirmation = remoteConfirmation else { return }
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai)
        guard remoteConfirmation?.id == confirmation.id,
              confirmation.configuration == settings.ai,
              confirmation.prepared.isCurrent(records: records, allowedKinds: allowedKinds) else { return }
        remoteConfirmation = nil
        do {
            let key = try settings.apiKey()
            _ = try confirmation.configuration.validated(apiKey: key)
            start(confirmation.prepared, configuration: confirmation.configuration, apiKey: key)
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissRemoteConfirmation() {
        guard remoteConfirmation != nil else { return }
        remoteConfirmation = nil
        statusMessage = "已取消发送，可继续查看本地检索结果。"
    }

    func cancel() {
        let hadPending = isPending || remoteConfirmation != nil
        task?.cancel(); task = nil; version = UUID()
        isPending = false; remoteConfirmation = nil
        if hadPending { statusMessage = "已取消本次回答。" }
    }

    private func invalidate() {
        cancel()
        prepared = nil; answer = nil; errorMessage = nil; statusMessage = nil
    }

    private func start(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?) {
        task?.cancel()
        let token = UUID(); version = token
        isPending = true; errorMessage = nil; statusMessage = nil
        let service = answerService
        task = Task { [weak self] in
            do {
                let result = try await service.answer(evidence, configuration: configuration, apiKey: apiKey)
                try Task.checkCancellation()
                guard let self, self.version == token else { return }
                guard evidence.isCurrent(records: self.latestRecords, allowedKinds: self.latestAllowedKinds),
                      self.latestConfiguration == configuration else {
                    self.invalidate()
                    self.statusMessage = "记录或读取权限已变化，请重新提问。"
                    return
                }
                self.answer = Answer(question: evidence.question, text: result, generated: true,
                                     provider: configuration.mode == .local ? "Apple 本地模型" : configuration.label)
                self.isPending = false; self.task = nil
            } catch {
                guard let self, self.version == token else { return }
                self.isPending = false; self.task = nil
                if error is CancellationError { self.statusMessage = "已取消本次回答。" }
                else { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
