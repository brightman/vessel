import Foundation
import Combine
import FoundationModels

actor NotebookIdeaStore {
    private var database: DaybookDatabase?
    private func open() throws -> DaybookDatabase {
        if let database { return database }
        let value=try DaybookDatabase(); database=value; return value
    }
    struct Page: Sendable {
        let rows: [FlashAsset]
        let totals: [FlashCurrencyTotal]
        let months: [String]
        let drafts: [NotebookIdeaDraft]
    }
    func page(kind: FlashAsset.Kind, month: String?, currency: String?, direction: FlashAsset.Direction?, pending: Bool, revoked: Bool, offset: Int) throws -> Page {
        let db=try open(), repo=try FlashCaptureRepository(database:db)
        return try .init(rows:repo.assets(kind:kind,month:month,currency:currency,direction:direction,pendingOnly:pending,showRevoked:revoked,limit:50,offset:offset),
            totals:kind == .expense ? repo.totals(month:month) : [], months:repo.months(),
            drafts:kind == .idea ? NotebookIdeaRepository(database:db).drafts() : [])
    }
    func save(_ asset: FlashAsset) throws -> FlashAsset { try FlashCaptureRepository(database:open()).save(asset) }
    func saveDraft(_ draft: NotebookIdeaDraft) throws { try Task.checkCancellation(); try NotebookIdeaRepository(database:open()).save(draft) }
    func accept(_ draft: NotebookIdeaDraft, ids: Set<UUID>) throws -> [FlashAsset] { try NotebookIdeaRepository(database:open()).accept(draftID:draft.id,candidateIDs:ids) }
    func discard(_ draft: NotebookIdeaDraft) throws { try NotebookIdeaRepository(database:open()).discard(draft.id) }
    func seedsAreCurrent(_ seeds: [FlashAsset]) throws -> Bool {
        let repo=try FlashCaptureRepository(database:open())
        return try seeds.allSatisfy { seed in
            guard let current=try repo.asset(seed.id) else { return false }
            return current == seed && !current.revoked
        }
    }
}

@MainActor final class NotebookIdeasModel: ObservableObject {
    @Published private(set) var rows: [FlashAsset] = []
    @Published private(set) var totals: [FlashCurrencyTotal] = []
    @Published private(set) var months: [String] = []
    @Published private(set) var drafts: [NotebookIdeaDraft] = []
    @Published private(set) var loading=false
    @Published private(set) var canLoadMore=false
    @Published private(set) var generating=false
    @Published var error: String?
    @Published var result: NotebookIdeaDraft?
    var kind: FlashAsset.Kind = .idea
    var month = NotebookIdeasModel.currentMonth
    var currency: String?
    var direction: FlashAsset.Direction?
    var pending=false
    var showRevoked=false
    private let store=NotebookIdeaStore()
    private var loadID=UUID()
    private var runID=UUID()
    private var generationTask: Task<Void,Never>?
    private var generationSettingsObservation: AnyCancellable?
    static var currentMonth: String {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="yyyy-MM"; return f.string(from:.now)
    }
    func reload(more: Bool = false) async {
        if more && (loading || !canLoadMore) { return }
        let id=UUID(); loadID=id; loading=true
        let offset=more ? rows.count : 0
        if !more { rows=[]; totals=[]; canLoadMore=false }
        do {
            let page=try await store.page(kind:kind,month:kind == .expense ? month : nil,currency:currency,direction:direction,pending:pending,revoked:showRevoked,offset:offset)
            guard id == loadID, !Task.isCancelled else { return }
            rows=more ? rows+page.rows : page.rows; totals=page.totals; months=Array(Set(page.months+[Self.currentMonth,month])).sorted(by:>)
            drafts=page.drafts; canLoadMore=page.rows.count == 50; loading=false; error=nil
        } catch { if id == loadID { self.error=error.localizedDescription; loading=false } }
    }
    func save(_ asset: FlashAsset) async -> Bool {
        do { _=try await store.save(asset); await reload(); return true }
        catch { self.error=error.localizedDescription; return false }
    }
    func accept(_ draft: NotebookIdeaDraft, ids: Set<UUID>) async -> Bool {
        do {
            _=try await store.accept(draft,ids:ids); result=nil; await reload(); return true
        } catch { self.error=error.localizedDescription; return false }
    }
    func discard(_ draft: NotebookIdeaDraft) async -> Bool {
        do { try await store.discard(draft); result=nil; await reload(); return true }
        catch { self.error=error.localizedDescription; return false }
    }
    func configuration(seeds: [FlashAsset], settings: AppSettings) -> AIConfiguration {
        let localOnly=seeds.contains { $0.requiresLocalAI == true || $0.source.device == "EurekaRing" || $0.parentIdeas?.contains { $0.source.device == "EurekaRing" } == true }
        return localOnly ? AIConfiguration() : settings.ai
    }
    func cancelGeneration() { runID=UUID(); generationTask?.cancel(); generationTask=nil; generationSettingsObservation=nil; generating=false }
    func generate(seeds: [FlashAsset], direction: String, settings: AppSettings, approvedConfiguration: AIConfiguration?, approvedRevision: Int?) {
        cancelGeneration(); error=nil
        let id=UUID(); runID=id
        let config=configuration(seeds:seeds,settings:settings), revision=settings.aiRevision
        do {
            _=try NotebookIdeaGeneration.context(seeds,direction:direction)
            if config.isRemote && settings.requiresRemoteAIConfirmation {
                guard approvedConfiguration == config, approvedRevision == revision else { throw ActionFailure.invalid("请确认将所选灵感发送到当前 AI 模型。") }
            }
        } catch { self.error=error.localizedDescription; return }
        generating=true
        generationSettingsObservation=Publishers.Merge(
            settings.$aiRevision.dropFirst().map { _ in () },
            settings.$requiresRemoteAIConfirmation.dropFirst().map { _ in () }
        ).sink { [weak self] _ in
            self?.cancelGeneration(); self?.error="AI 设置已改变，请重新发起生成。"
        }
        generationTask=Task { [weak self, settings] in
            guard let self else { return }
            defer { if self.runID == id { self.generating=false; self.generationTask=nil; self.generationSettingsObservation=nil } }
            do {
                let isCurrent: @MainActor () -> Bool = { [weak self, weak settings] in
                    guard let self, let settings else { return false }
                    return self.runID == id && settings.aiRevision == revision && self.configuration(seeds:seeds,settings:settings) == config
                        && (!config.isRemote || !settings.requiresRemoteAIConfirmation || (approvedConfiguration == config && approvedRevision == revision))
                }
                let seedsCurrent=try await self.store.seedsAreCurrent(seeds)
                try Task.checkCancellation()
                guard seedsCurrent, isCurrent() else { throw ActionFailure.changed }
                let content=try NotebookIdeaGeneration.context(seeds,direction:direction)
                let reply: String
                switch config.mode {
                case .local:
                    guard case .available = SystemLanguageModel.default.availability else { throw SummaryFailure.unavailable }
                    reply=try await LanguageModelSession(instructions:NotebookIdeaGeneration.instruction).respond(to:content,options:GenerationOptions(maximumResponseTokens:2200)).content
                case .custom:
                    reply=try await CustomAISummarizer().insight(content,instruction:NotebookIdeaGeneration.instruction,configuration:config,apiKey:settings.apiKey())
                case .nearbyMac:
                    reply=try await NearbyMacClient.shared.generate(content:content,instruction:NotebookIdeaGeneration.instruction,configuration:config,isCurrent:isCurrent)
                case .chatgpt:
                    reply=try await settings.chatGPT.complete(instruction:NotebookIdeaGeneration.instruction,content:content,modelID:config.chatGPTModel,accountID:config.chatGPTAccountID,isCurrent:isCurrent)
                }
                try Task.checkCancellation(); guard isCurrent() else { throw ActionFailure.changed }
                let sourcesUnchanged=try await self.store.seedsAreCurrent(seeds)
                try Task.checkCancellation(); guard sourcesUnchanged, isCurrent() else { throw ActionFailure.changed }
                let draft=NotebookIdeaDraft(seeds:seeds,direction:direction,candidates:try NotebookIdeaGeneration.parse(reply))
                try await self.store.saveDraft(draft)
                guard self.runID == id else { return }
                self.result=draft; await self.reload()
            } catch is CancellationError { }
            catch { if self.runID == id { self.error=error.localizedDescription } }
        }
    }
}
