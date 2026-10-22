import Combine
import Foundation

protocol ChatGPTServing {
    func authorizationURL(attempt: ChatGPTAuthorizationAttempt) throws -> URL
    func exchange(callbackURL: URL, attempt: ChatGPTAuthorizationAttempt) async throws -> ChatGPTCredential
    func refresh(_ credential: ChatGPTCredential) async throws -> ChatGPTCredential
    func models(accessToken: String) async throws -> [ChatGPTModel]
    func complete(instruction: String, content: String, model: String, accessToken: String) async throws -> String
    func revoke(_ credential: ChatGPTCredential) async throws
}
extension ChatGPTAPI: ChatGPTServing {}

@MainActor
final class ChatGPTAccountModel: ObservableObject {
    static let shared = ChatGPTAccountModel()
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    enum Status: Equatable { case disconnected, connected, expired, permissionMissing, limited }
    @Published private(set) var accounts: [ChatGPTRegistration] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isDisconnecting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0
    @Published private(set) var needsStorageRecovery = false
    @Published private(set) var isRecoveringStorage = false
    let isEnabled: Bool
    private let api: any ChatGPTServing
    private let storage: any ChatGPTAccountStoring
    private let defaults: UserDefaults
    private let disconnectMarker = "chatgpt.pendingDisconnect"
    private var vault = ChatGPTAccountVault()
    private var storageFailed: Bool { needsStorageRecovery }
    private var storageLoaded = false
    private var pendingVault: ChatGPTAccountVault?
    private var generation = 0
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: (id: UUID, task: Task<ChatGPTCredential, Error>)?
    private var catalogTask: (id: UUID, task: Task<[ChatGPTModel], Error>)?
    private var requestTasks: [UUID: Task<String, Error>] = [:]
    #if os(iOS)
    private let browser = ChatGPTBrowserAuthorization()
    #endif

    init(storage: any ChatGPTAccountStoring = ChatGPTKeychainStore(), api: any ChatGPTServing = ChatGPTAPI(), defaults: UserDefaults = .standard,
         isEnabled: Bool = Bundle.main.object(forInfoDictionaryKey: "WiseLifeChatGPTPublicClientEnabled") as? Bool ?? false) {
        self.storage = storage; self.api = api; self.defaults = defaults; self.isEnabled = isEnabled
        do {
            vault = try storage.load() ?? ChatGPTAccountVault()
            storageLoaded = true
            if defaults.string(forKey: disconnectMarker) != nil { try persist(vault) }
            else { publish() }
        } catch {
            needsStorageRecovery = true
            errorMessage = ChatGPTError.storage.localizedDescription
        }
    }

    var activeAccount: ChatGPTRegistration? { accounts.first { $0.id == selectedID } }
    var needsPlanNotice: Bool { activeAccount?.credential?.canUsePlan == true && activeAccount?.acknowledgedPlan == false }
    var isReady: Bool { isEnabled && !storageFailed && status == .connected && !needsPlanNotice && !isDisconnecting }
    var statusLabel: String {
        if !isEnabled { return "ChatGPT 连接尚未开通" }
        if isConnecting { return "正在等待 ChatGPT 授权…" }
        switch status {
        case .disconnected: return "未连接"
        case .connected: return "已连接"
        case .expired: return "授权已过期"
        case .permissionMissing: return "尚未允许使用 ChatGPT 套餐"
        case .limited: return "ChatGPT 用量已达上限"
        }
    }

    func canSave(modelID: String, accountID: String) -> Bool {
        isReady && !isConnecting && accountID == selectedID && models.contains { $0.id == modelID }
    }

    private func publish() {
        accounts = vault.registrations; selectedID = vault.selectedID
        if let credential = activeAccount?.credential { status = credential.canUsePlan ? .connected : .permissionMissing }
        else { status = activeAccount == nil ? .disconnected : .expired }
    }
    private func applyingPendingDisconnect(_ candidate: ChatGPTAccountVault) -> ChatGPTAccountVault {
        var cleaned = candidate
        if let id = defaults.string(forKey: disconnectMarker),
           let index = cleaned.registrations.firstIndex(where: { $0.id == id }) {
            cleaned.registrations[index].credential = nil
        }
        return cleaned
    }

    private func persist(_ candidate: ChatGPTAccountVault) throws {
        // Never save a newly generated empty vault over storage whose read failed.
        guard storageLoaded else { throw ChatGPTError.storage }
        let candidate = applyingPendingDisconnect(candidate)
        do { try storage.save(candidate) }
        catch {
            // Retain the complete rotating-token replacement until a durable retry.
            pendingVault = candidate; needsStorageRecovery = true
            // A failed pre-browser/accept save must release the connection latch too.
            connectionTask?.cancel(); connectionTask = nil; isConnecting = false
            #if os(iOS)
            browser.cancel()
            #endif
            invalidate(); models = []
            errorMessage = ChatGPTError.storage.localizedDescription
            throw ChatGPTError.storage
        }
        vault = candidate; pendingVault = nil; needsStorageRecovery = false
        publish()
        // This marker may only disappear after the credential removal was saved.
        defaults.removeObject(forKey: disconnectMarker)
    }

    func retryStorage() async {
        guard needsStorageRecovery, !isRecoveringStorage, !isDisconnecting, !isConnecting else { return }
        isRecoveringStorage = true
        defer { isRecoveringStorage = false }
        invalidate(); models = []
        do {
            if !storageLoaded {
                let recovered = try storage.load() ?? ChatGPTAccountVault()
                vault = recovered; storageLoaded = true
                if defaults.string(forKey: disconnectMarker) != nil { try persist(recovered) }
                else { needsStorageRecovery = false; publish() }
            } else {
                try persist(pendingVault ?? vault)
            }
            errorMessage = nil
            await loadModels()
        } catch {
            needsStorageRecovery = true
            errorMessage = ChatGPTError.storage.localizedDescription
        }
    }
    private func invalidate() {
        generation += 1; revision += 1
        isLoadingModels = false
        refreshTask?.task.cancel(); refreshTask = nil
        catalogTask?.task.cancel(); catalogTask = nil
        requestTasks.values.forEach { $0.cancel() }; requestTasks.removeAll()
    }

    func acknowledgePlan() {
        guard !storageFailed, let index = vault.registrations.firstIndex(where: { $0.id == selectedID }) else { return }
        var candidate = vault; candidate.registrations[index].acknowledgedPlan = true
        do { try persist(candidate); revision += 1 }
        catch { errorMessage = ChatGPTError.storage.localizedDescription }
    }

    func selectAccount(_ id: String) async {
        guard !storageFailed, !isConnecting, !isDisconnecting, vault.registrations.contains(where: { $0.id == id }) else { return }
        invalidate(); models = []; errorMessage = nil
        var candidate = vault; candidate.selectedID = id
        do { try persist(candidate); await loadModels() }
        catch { errorMessage = ChatGPTError.storage.localizedDescription }
    }

    func signIn(accountID: String? = nil) {
        guard isEnabled else { errorMessage = ChatGPTError.unavailableConfiguration.localizedDescription; return }
        guard !storageFailed, !isConnecting, !isDisconnecting else { return }
        #if os(iOS)
        isConnecting = true; errorMessage = nil
        let original = vault.registrations.first { $0.id == accountID }
        let version = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == version { self.isConnecting = false; self.connectionTask = nil } }
            do {
                // Save this device's opaque identity before the first browser request.
                try self.persist(self.vault)
                var attempt: ChatGPTAuthorizationAttempt?
                let callback = try await self.browser.authorize { callbackURL in
                    let value = try ChatGPTAuthorizationAttempt(callbackURL: callbackURL, clientID: original?.clientID,
                        hostID: self.vault.hostID, idTokenHint: original?.credential?.idToken,
                        loginHint: original?.email, expectedSubject: original?.subject)
                    attempt = value
                    return try self.api.authorizationURL(attempt: value)
                }
                guard let attempt else { throw ChatGPTError.invalidCallback }
                let credential = try await self.api.exchange(callbackURL: callback, attempt: attempt)
                try Task.checkCancellation()
                guard self.generation == version else { return }
                try self.accept(credential)
                self.isConnecting = false; self.connectionTask = nil
                await self.loadModels()
            } catch {
                guard self.generation == version else { return }
                if !(error is CancellationError), (error as? ChatGPTError) != .cancelled { self.errorMessage = error.localizedDescription }
            }
        }
        #else
        errorMessage = ChatGPTError.unavailableConfiguration.localizedDescription
        #endif
    }

    /// Only called with credentials whose identity and grant were verified by ChatGPTAPI.
    func accept(_ credential: ChatGPTCredential) throws {
        guard !storageFailed else { throw ChatGPTError.storage }
        guard credential.hostID == vault.hostID else { throw ChatGPTError.invalidIdentity }
        var candidate = vault
        if let index = candidate.registrations.firstIndex(where: { $0.id == credential.clientID }) {
            guard candidate.registrations[index].subject == credential.subject else { throw ChatGPTError.invalidIdentity }
            candidate.registrations[index].credential = credential
        } else {
            candidate.registrations.append(ChatGPTRegistration(clientID: credential.clientID, subject: credential.subject,
                email: credential.email, credential: credential))
        }
        candidate.selectedID = credential.clientID
        try persist(candidate); invalidate(); models = []
    }

    func cancelSignIn() {
        guard isConnecting else { return }
        connectionTask?.cancel(); connectionTask = nil
        #if os(iOS)
        browser.cancel()
        #endif
        invalidate(); isConnecting = false
    }

    func loadModels() async {
        guard isEnabled, !storageFailed, activeAccount?.credential?.canUsePlan == true, !isDisconnecting else { return }
        let version = generation
        do {
            let available = try await obtainModels()
            if available.isEmpty { errorMessage = "此账号暂时没有可用模型。" }
        } catch { if version == generation { record(error) } }
    }

    private func obtainModels() async throws -> [ChatGPTModel] {
        if let catalogTask { return try await catalogTask.task.value }
        let id = UUID(), version = generation
        isLoadingModels = true; errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let credential = try await self.validCredential()
            let available = try await self.api.models(accessToken: credential.accessToken)
            try Task.checkCancellation()
            guard self.generation == version else { throw CancellationError() }
            self.models = available
            return available
        }
        catalogTask = (id, task)
        defer { if catalogTask?.id == id { catalogTask = nil; isLoadingModels = false } }
        return try await task.value
    }

    private func validCredential() async throws -> ChatGPTCredential {
        guard isEnabled else { throw ChatGPTError.unavailableConfiguration }
        guard !storageFailed else { throw ChatGPTError.storage }
        guard !isDisconnecting, let credential = activeAccount?.credential else { throw ChatGPTError.expired }
        guard credential.canUsePlan else { throw ChatGPTError.permissionMissing }
        if credential.expiresAt.timeIntervalSinceNow > 60 { return credential }
        if let refreshTask { return try await refreshTask.task.value }
        let version = generation, id = UUID()
        // All waiters await persistence as well as the network exchange. A rotated token
        // must never escape to a second caller before the replacement is safely saved.
        let task = Task { [weak self, api] in
            let updated = try await api.refresh(credential)
            try Task.checkCancellation()
            guard let self, self.generation == version, self.selectedID == updated.clientID,
                  updated.subject == credential.subject, updated.hostID == credential.hostID else { throw CancellationError() }
            var candidate = self.vault
            guard let index = candidate.registrations.firstIndex(where: { $0.id == updated.clientID }) else { throw CancellationError() }
            candidate.registrations[index].credential = updated
            do { try self.persist(candidate) }
            catch { throw ChatGPTError.storage }
            if !updated.canUsePlan { self.revision += 1; throw ChatGPTError.permissionMissing }
            return updated
        }
        refreshTask = (id, task)
        defer { if refreshTask?.id == id { refreshTask = nil } }
        do {
            return try await task.value
        } catch {
            if generation == version, (error as? ChatGPTError) == .expired { clearUnusableCredential() }
            throw error
        }
    }

    func complete(instruction: String, content: String, modelID: String, accountID: String,
                  isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> String {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard !storageFailed else { throw ChatGPTError.storage }
        guard accountID == selectedID, isReady else {
            if status == .limited { throw ChatGPTError.usageLimit }
            throw isEnabled ? ChatGPTError.expired : ChatGPTError.unavailableConfiguration
        }
        let version = generation
        do {
            let credential = try await validCredential()
            try Task.checkCancellation()
            guard isCurrent(), version == generation, selectedID == accountID else { throw CancellationError() }
            if models.isEmpty { _ = try await obtainModels() }
            try Task.checkCancellation()
            guard isCurrent(), isReady, version == generation, selectedID == accountID else { throw CancellationError() }
            guard models.contains(where: { $0.id == modelID }) else { throw ChatGPTError.invalidResponse }
            let requestID = UUID()
            let task = Task { [weak self, api] in
                try Task.checkCancellation()
                guard let self, isCurrent(), self.isReady, self.generation == version,
                      self.selectedID == accountID else { throw CancellationError() }
                // This MainActor check is immediately before invoking the transport.
                return try await api.complete(instruction: instruction, content: content, model: modelID, accessToken: credential.accessToken)
            }
            requestTasks[requestID] = task
            defer { requestTasks[requestID] = nil }
            let text = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard isCurrent(), version == generation, selectedID == accountID else { throw CancellationError() }
            return text
        } catch { if version == generation { record(error) }; throw error }
    }

    func retryUsage() async {
        guard status == .limited else { return }
        status = .connected; revision += 1; errorMessage = nil
        await loadModels()
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        cancelSignIn(); invalidate(); isDisconnecting = true; isLoadingModels = false
        defer { isDisconnecting = false }
        let id = selectedID
        let credential = (pendingVault ?? vault).registrations.first { $0.id == id }?.credential
        // Non-secret marker prevents restart from reviving credentials if Keychain is
        // temporarily unavailable while disconnecting. Removed only after durable deletion.
        if let id { defaults.set(id, forKey: disconnectMarker) }
        var revocationFailed = false
        if let credential {
            do { try await api.revoke(credential) }
            catch { revocationFailed = true }
        }
        var candidate = pendingVault ?? vault
        if let index = candidate.registrations.firstIndex(where: { $0.id == id }) { candidate.registrations[index].credential = nil }
        do { try persist(candidate); defaults.removeObject(forKey: disconnectMarker); models = []; revision += 1
            errorMessage = revocationFailed ? "已在本机断开，未能确认云端撤销。请在 ChatGPT 设置中移除此应用的访问权限。" : nil
        } catch {
            // Do not resume use of a token after the user requested disconnection.
            vault = applyingPendingDisconnect(candidate); publish(); models = []
            errorMessage = "已停止使用此账号，但钥匙串清理失败。请重试断开，并在 ChatGPT 设置中撤销访问。"
        }
    }

    private func clearUnusableCredential() {
        var candidate = vault
        if let index = candidate.registrations.firstIndex(where: { $0.id == selectedID }) { candidate.registrations[index].credential = nil }
        do { try persist(candidate) } catch { vault = candidate; publish() }
        invalidate(); models = []; status = .expired
    }
    private func record(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
        if (error as? ChatGPTError) == .usageLimit { status = .limited; revision += 1 }
        if (error as? ChatGPTError) == .expired { clearUnusableCredential() }
        if (error as? ChatGPTError) == .permissionMissing { status = .permissionMissing; revision += 1 }
    }
}
