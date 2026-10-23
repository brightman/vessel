import SwiftUI

/// Account connections are saved by the account coordinator. Provider and model
/// choices remain in the settings editor's draft until the user saves it.
struct ChatGPTSettingsSection: View {
    @ObservedObject var account: ChatGPTAccountModel
    @Binding var configuration: AIConfiguration
    @State private var pendingAccountID = ""
    @State private var confirmsDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionStatus
            if account.needsStorageRecovery {
                storageRecovery
            } else if !account.isEnabled {
                SettingsInfo(title: "ChatGPT 连接尚未开通",
                             text: "此版本尚未启用 ChatGPT 登录。商业应用需要先获得 OpenAI 的接入资格，开通后才能连接账号。")
                continueButton.disabled(true)
            } else if account.isConnecting {
                SettingsFootnote(text: "请在 ChatGPT 授权页面完成登录。WiseLife 不会接收你的密码。")
                Button("取消授权") { account.cancelSignIn() }
                    .buttonStyle(DaybookSettingsButtonStyle())
            } else {
                recoveryNotice
                if !account.accounts.isEmpty { savedAccounts }
                if account.needsPlanNotice { planNotice }
                if account.activeAccount?.credential == nil {
                    continueButton
                } else if account.status == .expired || account.status == .permissionMissing {
                    Button("重新授权") { account.signIn(accountID: account.selectedID) }
                        .buttonStyle(DaybookSettingsButtonStyle(primary: true))
                        .disabled(account.isDisconnecting)
                } else {
                    modelSelection
                }
            }
            if account.activeAccount?.credential != nil && !account.isConnecting && !account.needsStorageRecovery { accountActions }
            if let message = account.errorMessage {
                Text(LocalizedStringKey(message))
                    .font(.system(size: 11)).foregroundStyle(DaybookStyle.red)
                    .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("ChatGPT 错误")
                    .accessibilityValue(Text(LocalizedStringKey(message)))
            }
            SettingsFootnote(text: "选中的文字会发送至 OpenAI 云端。原始录音、图片文件和声音档案留在本机；不会读取你的 ChatGPT 聊天记录。")
        }
        .padding(.top, 18)
        .task {
            alignDraftAccount()
            await account.loadModels()
        }
        .onChange(of: account.selectedID) { _, _ in alignDraftAccount() }
        .onChange(of: account.needsStorageRecovery) { _, needsRecovery in
            if needsRecovery { confirmsDisconnect = false }
        }
        .onDisappear { account.cancelSignIn() }
        .confirmationDialog("断开 ChatGPT 连接？", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("确认断开", role: .destructive) { Task { await account.disconnect() } }
            Button("保留连接", role: .cancel) {}
        } message: {
            Text("后续任务将停止使用此账号，已有笔记和对话保留。你可以重新连接，或在设置中选择其他模型。")
        }
    }

    private var connectionStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            if account.isConnecting || account.isDisconnecting || account.isRecoveringStorage {
                ProgressView().controlSize(.small).padding(.top, 2)
            } else {
                DaybookIcon(showsConnected ? "CheckCheck" : "MessageCircle", size: 18)
                    .foregroundStyle(showsConnected ? DaybookStyle.green : DaybookStyle.accent)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(account.needsStorageRecovery ? "ChatGPT 安全存储需要恢复" : account.isDisconnecting ? "正在断开 ChatGPT…" : account.statusLabel))
                    .font(.system(size: 13, weight: .medium))
                if let registration = account.activeAccount {
                    Text(verbatim: accountLabel(registration))
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                        .privacySensitive().textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var showsConnected: Bool {
        account.status == .connected && account.isEnabled && !account.needsStorageRecovery
    }

    private var storageRecovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsInfo(title: "账号安全存储暂不可用",
                         text: "ChatGPT 已暂停使用。请重试恢复本机安全存储；恢复成功后才能连接、切换或使用账号。")
            Button {
                Task { await account.retryStorage() }
            } label: {
                HStack(spacing: 7) {
                    if account.isRecoveringStorage { ProgressView().controlSize(.small) }
                    Text(LocalizedStringKey(account.isRecoveringStorage ? "正在恢复安全存储…" : "重试安全存储"))
                }
            }
            .buttonStyle(DaybookSettingsButtonStyle())
            .disabled(account.isRecoveringStorage)
            Link("管理用量", destination: ChatGPTAccountModel.usageURL)
                .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
        }
    }

    private var continueButton: some View {
        Button { account.signIn(accountID: account.selectedID) } label: {
            Text("Continue with ChatGPT").frame(maxWidth: .infinity)
        }
        .buttonStyle(DaybookSettingsButtonStyle(primary: true))
        .disabled(account.isDisconnecting)
    }

    @ViewBuilder private var recoveryNotice: some View {
        switch account.status {
        case .disconnected:
            SettingsFootnote(text: "用已有账号选择可用模型，无需填写 API Key。")
        case .expired:
            SettingsInfo(title: "授权已过期", text: "重新授权后才能继续使用 ChatGPT。")
        case .permissionMissing:
            SettingsInfo(title: "尚未允许使用 ChatGPT 套餐",
                         text: "请重新授权，并允许 WiseLife 使用 ChatGPT 套餐。可用性取决于账号和应用的接入资格。")
        case .limited:
            SettingsInfo(title: "ChatGPT 用量已达上限",
                         text: "请前往 ChatGPT 管理用量，或在设置中选择 Apple 本地模型。额度恢复后可重试。")
        case .connected:
            if !account.needsPlanNotice { SettingsFootnote(text: "使用 ChatGPT 套餐") }
        }
    }

    private var savedAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            DaybookSettingsField("已保存的 ChatGPT 账号") {
                Picker("已保存的 ChatGPT 账号", selection: $pendingAccountID) {
                    ForEach(account.accounts) { registration in
                        Text(verbatim: accountLabel(registration)).tag(registration.id)
                    }
                }
                .pickerStyle(.menu).labelsHidden().privacySensitive()
                .disabled(account.isDisconnecting)
            }
            HStack(spacing: 10) {
                Button("切换账号") {
                    let id = pendingAccountID
                    Task { await account.selectAccount(id) }
                }
                .disabled(pendingAccountID.isEmpty || pendingAccountID == account.selectedID || account.isDisconnecting || account.isLoadingModels)
                Button("添加账号") { account.signIn() }
                    .disabled(account.isDisconnecting || account.isLoadingModels)
            }
            .buttonStyle(DaybookSettingsButtonStyle())
        }
    }

    private var planNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsInfo(title: "使用你的 ChatGPT 套餐",
                         text: "此连接使用 ChatGPT 套餐的可用额度。WiseLife 的购买费用不包含 ChatGPT 订阅，也不代表无限用量。")
            Button("知道了") { account.acknowledgePlan() }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                .disabled(account.isDisconnecting)
        }
    }

    private var modelSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DaybookSettingsField("账号可用模型") {
                Picker("账号可用模型", selection: $configuration.chatGPTModel) {
                    if configuration.chatGPTModel.isEmpty {
                        Text("请选择可用模型").tag("")
                    } else if !account.models.contains(where: { $0.id == configuration.chatGPTModel }) {
                        Text(verbatim: configuration.chatGPTModel).tag(configuration.chatGPTModel)
                    }
                    ForEach(account.models) { model in
                        Text(verbatim: model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                .disabled(account.isLoadingModels || account.models.isEmpty || account.isDisconnecting)
            }
            if !configuration.chatGPTModel.isEmpty && !account.isLoadingModels &&
                !account.models.contains(where: { $0.id == configuration.chatGPTModel }) {
                SettingsFootnote(text: "已保存的模型暂不可用。请刷新模型列表，或主动选择其他模型后再保存。")
            }
            Button {
                Task {
                    if account.status == .limited { await account.retryUsage() }
                    else { await account.loadModels() }
                }
            } label: {
                HStack(spacing: 7) {
                    if account.isLoadingModels { ProgressView().controlSize(.small) }
                    Text(LocalizedStringKey(account.isLoadingModels ? "正在加载模型…" : account.status == .limited ? "额度恢复后重试" : "刷新可用模型"))
                }
            }
            .buttonStyle(DaybookSettingsButtonStyle())
            .disabled(account.isLoadingModels || account.isDisconnecting)
        }
    }

    private var accountActions: some View {
        HStack(spacing: 16) {
            Link(destination: ChatGPTAccountModel.usageURL) {
                HStack(spacing: 5) { Text("管理用量"); DaybookIcon("ArrowUpRight", size: 13) }
            }
            Spacer(minLength: 0)
            Button("断开连接") { confirmsDisconnect = true }
                .foregroundStyle(DaybookStyle.red).disabled(account.isDisconnecting)
        }
        .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
    }

    private func alignDraftAccount() {
        pendingAccountID = account.selectedID ?? account.accounts.first?.id ?? ""
        configuration.chatGPTAccountID = account.selectedID ?? ""
    }

    private func accountLabel(_ registration: ChatGPTRegistration) -> String {
        let email = registration.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = email.flatMap { $0.isEmpty ? nil : $0 }
        let duplicates = account.accounts.filter {
            $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email?.lowercased()
        }
        guard let name else { return String(localized: "ChatGPT 账号") + " · " + uniqueSuffix(registration) }
        return duplicates.count > 1 ? name + " · " + uniqueSuffix(registration) : name
    }

    private func uniqueSuffix(_ registration: ChatGPTRegistration) -> String {
        var length = min(8, registration.clientID.count)
        while length < registration.clientID.count && account.accounts.contains(where: {
            $0.id != registration.id && $0.clientID.suffix(length) == registration.clientID.suffix(length)
        }) { length += 1 }
        return String(registration.clientID.suffix(length))
    }
}
