import SwiftUI
import UIKit

@MainActor final class NearbyMacSettingsModel: ObservableObject {
    @Published var code = ""
    @Published private(set) var name = ""
    @Published private(set) var serviceID = ""
    @Published private(set) var modelID = ""
    @Published private(set) var message: String?
    @Published private(set) var result: String?
    @Published private(set) var busy = false
    enum VerificationState {
        case idle, running(String), succeeded(String), failed(String), cancelled
    }
    @Published private(set) var verification: VerificationState = .idle
    private var operationID = UUID()
    private var operation: Task<Void, Never>?

    func restore() async {
        do {
            if let peer = try await NearbyMacClient.shared.peer() { name = peer.name; serviceID = peer.serviceID }
        } catch { message = error.localizedDescription }
    }
    func pair(settings: AppSettings, selected: @escaping (AIConfiguration) -> Void) {
        run {
            let peer = try await NearbyMacClient.shared.pair(self.code, deviceName: UIDevice.current.name)
            try Task.checkCancellation()
            self.name = peer.name; self.serviceID = peer.serviceID; self.code = ""
            var configuration = settings.ai
            configuration.mode = .nearbyMac; configuration.nearbyMacServiceID = peer.serviceID; configuration.nearbyMacName = peer.name
            configuration.model = ""; configuration.baseURL = ""; configuration.apiProtocol = .openai
            // Pairing is an explicit selection of this recipient for summaries, titles and Q&A.
            try settings.saveAI(configuration, apiKey: ""); selected(settings.ai)
            self.message = "配对成功，之后的总结、标题和问答使用这台 Mac 的模型。"
            let pairedRevision = settings.aiRevision
            do {
                self.modelID = try await NearbyMacClient.shared.readiness(serviceID: peer.serviceID)
                try Task.checkCancellation()
                if settings.aiRevision == pairedRevision {
                    var ready = settings.ai; ready.model = self.modelID
                    try settings.saveAI(ready, apiKey: ""); selected(settings.ai)
                }
                self.message = "已连接，Mac 模型已就绪。"
            } catch { self.message = "已配对。" + error.localizedDescription }
        }
    }
    func verify(settings: AppSettings) {
        run(diagnostic: true) {
            self.verification = .running("1/4 · 正在连接 Mac 并检查模型…")
            let start = Date()
            let configuration = settings.ai, revision = settings.aiRevision
            guard configuration.mode == .nearbyMac else { throw AIServiceError.invalidConfiguration("请先使用这台 Mac 作为 AI 模型。") }
            let current: @MainActor () -> Bool = { !Task.isCancelled && settings.ai == configuration && settings.aiRevision == revision }
            self.modelID = try await NearbyMacClient.shared.readiness(serviceID: configuration.nearbyMacServiceID)
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            self.verification = .running("2/4 · 已连接，正在生成示例总结…")
            let sample = "项目会议记录：周五下午三点复核预算，李明负责整理预算表，王芳负责联系场地。大家同意先完成预算确认，再预订场地。"
            let summary = try await CustomAISummarizer().summarize(sample, configuration: configuration, apiKey: "", isCurrent: current)
            self.verification = .running("3/4 · 总结已返回，正在测试问答…")
            let answer = try await CustomAISummarizer().answer(question: "谁负责整理预算表？请引用资料编号。", context: "[1] " + sample,
                configuration: configuration, apiKey: "", isCurrent: current)
            self.verification = .running("4/4 · 问答已返回，正在生成标题…")
            let title = try await CustomAISummarizer().recordingTitle(sample, configuration: configuration, apiKey: "", isCurrent: current)
            guard current() else { throw CancellationError() }
            guard answer.contains("[1]"), answer.contains("李明"), !summary.isEmpty else { throw NearbyMacFailure.response }
            guard !title.isEmpty else { throw NearbyMacFailure.response }
            self.result = "总结：\n\(summary)\n\n问答：\n\(answer)\n\n标题：\(title)"
            self.verification = .succeeded("连接、总结、问答和标题均通过，用时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒。")

        }
    }
    func unpair(settings: AppSettings, localOnly: Bool, selected: @escaping (AIConfiguration) -> Void) {
        run {
            try await NearbyMacClient.shared.unpair(localOnly: localOnly)
            self.name = ""; self.serviceID = ""; self.modelID = ""; self.result = nil
            var configuration = settings.ai; configuration.mode = .local
            try settings.saveAI(configuration, apiKey: ""); selected(settings.ai)
            self.message = localOnly ? "本机配对已移除。可在原 Mac 上撤销此 iPhone。" : "配对已撤销。"
        }
    }
    func cancel() {
        operationID = UUID()
        operation?.cancel(); operation = nil; busy = false
        if case .running = verification { verification = .cancelled }
    }
    private func run(diagnostic: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil; result = nil
        verification = diagnostic ? .running("正在开始测试…") : .idle
        let id = UUID(); operationID = id
        operation = Task {
            defer { if self.operationID == id { self.busy = false; self.operation = nil } }
            do { try await body() }
            catch is CancellationError {
                if self.operationID == id, diagnostic { self.verification = .cancelled }
            }
            catch {
                guard self.operationID == id else { return }
                if diagnostic { self.verification = .failed(error.localizedDescription) }
                else { self.message = error.localizedDescription }
            }
        }
    }

}

struct NearbyMacSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @Binding var configuration: AIConfiguration
    var initialCode = ""
    @StateObject private var model = NearbyMacSettingsModel()
    @State private var scanning = false
    @State private var removing = false
    @ViewBuilder private var verificationFeedback: some View {
        switch model.verification {
        case .idle: EmptyView()
        case .running(let detail):
            VStack(alignment: .leading, spacing: 10) {
                HStack { ProgressView(); Text("测试中").font(.headline) }
                Text(detail).font(.subheadline)
                Text("Mac 首次生成可能较慢，请保持服务运行。").font(.caption).foregroundStyle(.secondary)
                Button("取消测试") { model.cancel() }.font(.subheadline)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("nearbyMac.testing")
        case .succeeded(let detail):
            feedbackCard(title: "测试成功", detail: detail, symbol: "checkmark.circle.fill", color: .green)
            if let result = model.result {
                DisclosureGroup("查看测试生成内容") {
                    Text(result).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("nearbyMac.result")
            }
        case .failed(let reason):
            feedbackCard(title: "测试失败", detail: reason, symbol: "xmark.circle.fill", color: .red)
        case .cancelled:
            feedbackCard(title: "测试已取消", detail: "测试未完成，可重新点击测试。模型或授权变化也会终止测试。",
                         symbol: "minus.circle.fill", color: .secondary)
        }
    }
    private func feedbackCard(title: String, detail: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            Text(detail).font(.subheadline).foregroundStyle(DaybookStyle.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nearbyMac.testOutcome")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsInfo(title: model.name.isEmpty ? "连接附近的 Mac" : model.name,
                text: "配对后，笔记总结、录音标题与 AI 问答使用桌面端当前加载的模型。允许发送的文字经局域网加密传输，音频和照片留在 iPhone。发送前确认偏好继续有效。")
            if !model.serviceID.isEmpty {
                Text("已配对 · \(model.serviceID.prefix(8))").font(.caption).foregroundStyle(DaybookStyle.secondary)
                if !model.modelID.isEmpty { Text(model.modelID).font(.caption).textSelection(.enabled) }
                Button("测试连接与总结") { model.verify(settings: settings) }
                    .buttonStyle(DaybookSettingsButtonStyle()).disabled(model.busy)
                    .accessibilityIdentifier("nearbyMac.verify")
                verificationFeedback
                SettingsFootnote(text: "测试仅发送固定的示例会议文字，验证真实桌面模型的总结和带引用问答，不读取你的记录。")
                Button("解除配对", role: .destructive) { removing = true }.font(.caption).disabled(model.busy)
            }
            Text("在 Mac 打开“配对 iPhone”，扫描新生成的二维码。请保持两端连接同一网络。")
                .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
            Button { scanning = true } label: { Label("扫描 Mac AI 配对码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(model.busy)
                .accessibilityIdentifier("nearbyMac.scan")
            TextField("粘贴 Mac AI 配对链接", text: $model.code, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...4)
                .font(.system(size: 12)).padding(14).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 12))
                .privacySensitive().accessibilityIdentifier("nearbyMac.pairingCode")
            Button("配对并使用 Mac 本地模型") { model.pair(settings: settings) { configuration = $0 } }
                .buttonStyle(DaybookSettingsButtonStyle()).disabled(model.code.isEmpty || model.busy)
                .accessibilityIdentifier("nearbyMac.pair")
            if model.busy, case .idle = model.verification { HStack { ProgressView(); Text("正在连接 Mac…").font(.caption) } }
            if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).accessibilityIdentifier("nearbyMac.status") }

        }
        .task {
            model.code = initialCode
            await model.restore()
            // Recover an existing Keychain pairing without requiring another scan.
            if configuration.nearbyMacServiceID.isEmpty, !model.serviceID.isEmpty {
                configuration.nearbyMacServiceID = model.serviceID
                configuration.nearbyMacName = model.name
            }
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $scanning) {
            DesktopPairingScanner(onCode: { model.code = $0; scanning = false }, prefix: "wiselife-mac://pair")
        }
        .confirmationDialog("解除与 Mac 的配对？", isPresented: $removing, titleVisibility: .visible) {
            Button("在两端撤销配对", role: .destructive) { model.unpair(settings: settings, localOnly: false) { configuration = $0 } }
            Button("Mac 离线，仅移除本机配对", role: .destructive) { model.unpair(settings: settings, localOnly: true) { configuration = $0 } }
        } message: { Text("不会删除录音。移除后需重新扫码才能使用 Mac 模型。") }
    }
}
