import Foundation

private final class MemoryChatGPTStore: ChatGPTAccountStoring {
    var value: ChatGPTAccountVault?
    var failWrites = false
    var failReads = false
    var saveCount = 0
    var loadCount = 0
    init(_ value: ChatGPTAccountVault) { self.value = value }
    func load() throws -> ChatGPTAccountVault? { loadCount += 1; if failReads { throw ChatGPTError.storage }; return value }
    func save(_ vault: ChatGPTAccountVault) throws {
        saveCount += 1
        if failWrites { throw ChatGPTError.storage }
        value = vault
    }
}

private actor FixtureChatGPTAPI: ChatGPTServing {
    var refreshCount = 0, catalogCount = 0, requestCount = 0
    var refreshFailure: ChatGPTError?
    var hold = false
    var completionHook: (@MainActor () -> Void)?
    nonisolated func authorizationURL(attempt: ChatGPTAuthorizationAttempt) throws -> URL { URL(string: "https://auth.openai.com/api/accounts/authorize")! }
    func exchange(callbackURL: URL, attempt: ChatGPTAuthorizationAttempt) async throws -> ChatGPTCredential { throw ChatGPTError.invalidCallback }
    func refresh(_ credential: ChatGPTCredential) async throws -> ChatGPTCredential {
        refreshCount += 1
        try await Task.sleep(for: .milliseconds(30))
        if let refreshFailure { throw refreshFailure }
        return ChatGPTCredential(clientID: credential.clientID, subject: credential.subject, email: credential.email,
            hostID: credential.hostID, idToken: "fixture-id", accessToken: "rotated-fixture-access", refreshToken: "rotated-fixture-refresh",
            expiresAt: .now.addingTimeInterval(3600), scopes: credential.scopes)
    }
    func models(accessToken: String) async throws -> [ChatGPTModel] {
        catalogCount += 1
        try await Task.sleep(for: .milliseconds(15))
        return [.init(id: "fixture-model", displayName: "Fixture model")]
    }
    func complete(instruction: String, content: String, model: String, accessToken: String) async throws -> String {
        requestCount += 1
        if let completionHook { await completionHook() }
        if hold { try await Task.sleep(for: .seconds(30)) }
        return "Fixture answer [1]"
    }
    func revoke(_ credential: ChatGPTCredential) async throws {}
    func setFailure(_ error: ChatGPTError) { refreshFailure = error }
    func setHold() { hold = true }
    func setCompletionHook(_ hook: @escaping @MainActor () -> Void) { completionHook = hook }
    func counts() -> (Int, Int, Int) { (refreshCount, catalogCount, requestCount) }
}

@main
struct ChatGPTAccountSmoke {
    @MainActor static func main() async throws {
        let name = "chatgpt-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func vault(expired: Bool = false, acknowledged: Bool = true) -> ChatGPTAccountVault {
            let credential = ChatGPTCredential(clientID: "fixture-client", subject: "fixture-subject", email: "example@example.com",
                hostID: "urn:uuid:fixture", idToken: "fixture-id", accessToken: "fixture-access", refreshToken: "fixture-refresh",
                expiresAt: .now.addingTimeInterval(expired ? -60 : 3600), scopes: ["chatgpt.tokens.use.direct", "resource.invoke"])
            return ChatGPTAccountVault(hostID: credential.hostID, registrations: [ChatGPTRegistration(clientID: credential.clientID,
                subject: credential.subject, email: credential.email, credential: credential, acknowledgedPlan: acknowledged)], selectedID: credential.clientID)
        }
        let disabled = ChatGPTAccountModel(storage: MemoryChatGPTStore(vault()), api: FixtureChatGPTAPI(), defaults: defaults, isEnabled: false)
        precondition(!disabled.isReady && !disabled.canSave(modelID: "fixture-model", accountID: "fixture-client"))
        let noticeStore = MemoryChatGPTStore(vault(acknowledged: false))
        let notice = ChatGPTAccountModel(storage: noticeStore, api: FixtureChatGPTAPI(), defaults: defaults, isEnabled: true)
        precondition(notice.needsPlanNotice && !notice.isReady)
        notice.acknowledgePlan()
        await notice.loadModels()
        precondition(notice.isReady && notice.canSave(modelID: "fixture-model", accountID: "fixture-client"))
        precondition(!notice.canSave(modelID: "unknown-model", accountID: "fixture-client"))
        precondition(!notice.canSave(modelID: "fixture-model", accountID: "wrong-account"))

        let store = MemoryChatGPTStore(vault(expired: true)), api = FixtureChatGPTAPI()
        let account = ChatGPTAccountModel(storage: store, api: api, defaults: defaults, isEnabled: true)
        async let first = account.complete(instruction: "Fixture", content: "Selected text", modelID: "fixture-model", accountID: "fixture-client")
        async let second = account.complete(instruction: "Fixture", content: "Selected text", modelID: "fixture-model", accountID: "fixture-client")
        let answers = try await [first, second]
        precondition(answers.count == 2)
        let counts = await api.counts()
        precondition(counts.0 == 1 && counts.1 == 1 && counts.2 == 2, "refresh and catalog must be shared")
        precondition(store.value?.registrations[0].credential?.refreshToken == "rotated-fixture-refresh")

        await api.setHold()
        let pending = Task { try await account.complete(instruction: "Fixture", content: "Selected text", modelID: "fixture-model", accountID: "fixture-client") }
        while await api.counts().2 < 3 { await Task.yield() }
        await account.disconnect()
        do { _ = try await pending.value; fatalError("disconnected request returned a result") } catch is CancellationError {} catch { fatalError("unexpected cancellation type") }
        precondition(store.value?.registrations.first?.credential == nil && store.value?.registrations.first?.clientID == "fixture-client")
        precondition(!account.isReady)

        for failure in [ChatGPTError.network, .expired] {
            let failedStore = MemoryChatGPTStore(vault(expired: true)), failedAPI = FixtureChatGPTAPI()
            await failedAPI.setFailure(failure)
            let failed = ChatGPTAccountModel(storage: failedStore, api: failedAPI, defaults: defaults, isEnabled: true)
            await failed.loadModels()
            precondition((failedStore.value?.registrations.first?.credential == nil) == (failure == .expired))
        }
        let failedStore = MemoryChatGPTStore(vault(expired: true)), failedAPI = FixtureChatGPTAPI()
        failedStore.failWrites = true
        let failed = ChatGPTAccountModel(storage: failedStore, api: failedAPI, defaults: defaults, isEnabled: true)
        await failed.loadModels()
        precondition(!failed.isReady && failedStore.value?.registrations.first?.credential?.accessToken == "fixture-access")
        await failed.disconnect()
        precondition(defaults.string(forKey: "chatgpt.pendingDisconnect") == "fixture-client")
        let restarted = ChatGPTAccountModel(storage: failedStore, api: failedAPI, defaults: defaults, isEnabled: true)
        precondition(!restarted.isReady)
        failedStore.failWrites = false
        let recovered = ChatGPTAccountModel(storage: failedStore, api: failedAPI, defaults: defaults, isEnabled: true)
        precondition(!recovered.isReady && failedStore.value?.registrations.first?.credential == nil)
        precondition(defaults.string(forKey: "chatgpt.pendingDisconnect") == nil)
        // A failed cleanup must be recoverable in this process, without resurrecting tokens.
        let cleanupStore = MemoryChatGPTStore(vault()), cleanupAPI = FixtureChatGPTAPI()
        let cleanup = ChatGPTAccountModel(storage: cleanupStore, api: cleanupAPI, defaults: defaults, isEnabled: true)
        cleanupStore.failWrites = true
        await cleanup.disconnect()
        precondition(cleanup.needsStorageRecovery && !cleanup.isReady)
        cleanupStore.failWrites = false
        await cleanup.retryStorage()
        precondition(!cleanup.needsStorageRecovery && cleanupStore.value?.registrations.first?.credential == nil)
        precondition(defaults.string(forKey: "chatgpt.pendingDisconnect") == nil)

        let initialStore = MemoryChatGPTStore(vault()), initialAPI = FixtureChatGPTAPI()
        initialStore.failReads = true
        let initial = ChatGPTAccountModel(storage: initialStore, api: initialAPI, defaults: defaults, isEnabled: true)
        precondition(initial.needsStorageRecovery && initialStore.saveCount == 0)
        await initial.retryStorage()
        precondition(initial.needsStorageRecovery && initialStore.saveCount == 0, "unknown storage must never be overwritten")
        initialStore.failReads = false
        await initial.retryStorage()
        precondition(!initial.needsStorageRecovery && initial.isReady && initialStore.loadCount == 3 && initialStore.saveCount == 0)
        precondition(initial.activeAccount?.credential?.accessToken == "fixture-access")

        let acceptingStore = MemoryChatGPTStore(vault()), acceptingAPI = FixtureChatGPTAPI()
        let accepting = ChatGPTAccountModel(storage: acceptingStore, api: acceptingAPI, defaults: defaults, isEnabled: true)
        acceptingStore.failWrites = true
        let acceptedToken = ChatGPTCredential(clientID: "new-client", subject: "new-subject", email: nil, hostID: "urn:uuid:fixture",
            idToken: "new-id", accessToken: "new-access", refreshToken: "new-refresh", expiresAt: .now.addingTimeInterval(3600),
            scopes: ["chatgpt.tokens.use.direct", "resource.invoke"])
        do { try accepting.accept(acceptedToken); fatalError("failed acceptance persisted") } catch ChatGPTError.storage {}
        precondition(accepting.needsStorageRecovery && !accepting.isConnecting && !accepting.isRecoveringStorage)
        acceptingStore.failWrites = false
        await accepting.retryStorage()
        precondition(!accepting.needsStorageRecovery && accepting.selectedID == "new-client")
        precondition(acceptingStore.value?.registrations.last?.credential?.refreshToken == "new-refresh")

        let rotationStore = MemoryChatGPTStore(vault(expired: true)), rotationAPI = FixtureChatGPTAPI()
        let rotation = ChatGPTAccountModel(storage: rotationStore, api: rotationAPI, defaults: defaults, isEnabled: true)
        rotationStore.failWrites = true
        await rotation.loadModels()
        precondition(rotation.needsStorageRecovery && !rotation.isReady)
        rotationStore.failWrites = false
        await rotation.retryStorage()
        precondition(!rotation.needsStorageRecovery && rotation.isReady)
        precondition(rotationStore.value?.registrations.first?.credential?.refreshToken == "rotated-fixture-refresh")
        let rotationCounts = await rotationAPI.counts()
        precondition(rotationCounts.0 == 1, "retry must save the rotated token rather than refresh the old token")

        let markedStore = MemoryChatGPTStore(vault(expired: true)), markedAPI = FixtureChatGPTAPI()
        let marked = ChatGPTAccountModel(storage: markedStore, api: markedAPI, defaults: defaults, isEnabled: true)
        markedStore.failWrites = true
        await marked.loadModels()
        defaults.set("fixture-client", forKey: "chatgpt.pendingDisconnect")
        markedStore.failWrites = false
        await marked.retryStorage()
        precondition(!marked.needsStorageRecovery && !marked.isReady)
        precondition(markedStore.value?.registrations.first?.credential == nil)
        precondition(defaults.string(forKey: "chatgpt.pendingDisconnect") == nil, "retry applies marker before saving a pending rotation")

        for expired in [true, false] {
            let staleStore = MemoryChatGPTStore(vault(expired: expired)), staleAPI = FixtureChatGPTAPI()
            let stale = ChatGPTAccountModel(storage: staleStore, api: staleAPI, defaults: defaults, isEnabled: true)
            var current = true
            let request = Task { try await stale.complete(instruction: "Fixture", content: "Confirmed text", modelID: "fixture-model", accountID: "fixture-client", isCurrent: { current }) }
            while true {
                let count = await staleAPI.counts()
                if expired ? count.0 > 0 : count.1 > 0 { break }
                await Task.yield()
            }
            current = false
            do { _ = try await request.value; fatalError("stale consent sent inference") } catch is CancellationError {}
            let count = await staleAPI.counts()
            precondition(count.2 == 0, "no inference after consent invalidates during refresh/catalog")
        }
        let summaryStore = MemoryChatGPTStore(vault()), summaryAPI = FixtureChatGPTAPI()
        let summaryAccount = ChatGPTAccountModel(storage: summaryStore, api: summaryAPI, defaults: defaults, isEnabled: true)
        await summaryAccount.loadModels()
        var summaryCurrent = true
        await summaryAPI.setCompletionHook { summaryCurrent = false }
        var configuration = AIConfiguration()
        configuration.mode = .chatgpt; configuration.chatGPTAccountID = "fixture-client"; configuration.chatGPTModel = "fixture-model"
        do {
            _ = try await ChatGPTSummarizer(account: summaryAccount).summarize(String(repeating: "a", count: 13_000), configuration: configuration, isCurrent: { summaryCurrent })
            fatalError("invalidated summary continued")
        } catch is CancellationError {}
        let summaryCounts = await summaryAPI.counts()
        precondition(summaryCounts.2 == 1, "summary must not send another chunk after invalidation")
        print("ChatGPT account lifecycle: passed (eligibility, catalog, serialized refresh, consent guards, summary cancellation, durable disconnect, storage retry)")
    }
}
