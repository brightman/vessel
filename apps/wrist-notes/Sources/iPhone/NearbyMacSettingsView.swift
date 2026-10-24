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
    private var operation: Task<Void, Never>?
    func show(error: Error) { message = error.localizedDescription }

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
    func check() {
        run {
            self.modelID = try await NearbyMacClient.shared.readiness(serviceID: self.serviceID)
            self.message = "已连接，Mac 模型已就绪。"
        }
    }
    func verify(settings: AppSettings) {
        run(diagnostic: true) {
            let configuration = settings.ai, revision = settings.aiRevision
            guard configuration.mode == .nearbyMac else { throw AIServiceError.invalidConfiguration("请先使用这台 Mac 作为 AI 模型。") }
            let current: @MainActor () -> Bool = { settings.ai == configuration && settings.aiRevision == revision }
            self.modelID = try await NearbyMacClient.shared.readiness(serviceID: configuration.nearbyMacServiceID)
            let start = Date()
            let sample = "项目会议记录：周五下午三点复核预算，李明负责整理预算表，王芳负责联系场地。大家同意先完成预算确认，再预订场地。"
            let summary = try await CustomAISummarizer().summarize(sample, configuration: configuration, apiKey: "", isCurrent: current)
            let answer = try await CustomAISummarizer().answer(question: "谁负责整理预算表？请引用资料编号。", context: "[1] " + sample,
                configuration: configuration, apiKey: "", isCurrent: current)
            let title = try await CustomAISummarizer().recordingTitle(sample, configuration: configuration, apiKey: "", isCurrent: current)
            let segment = try await ConfiguredContentTextModel.respond(.init(kind: .summary, text: sample),
                configuration: configuration, revision: revision, settings: settings, authorizedForRequest: true)
            let now = Date()
            let records = [DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-60), kind: .voice, title: "项目会议", text: sample),
                DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-30), kind: .voice, title: "会后安排", text: "李明会在周五午前把预算表发送给大家，之后王芳根据已批准的预算预订场地。")]
            let evidence = try DaybookInsightModel.prepare(records: records, selectedDate: now, allowedKinds: [.voice], now: now)
            let insight = try await DaybookInsightService().generate(evidence, language: "zh-Hans", now: now,
                configuration: configuration, apiKey: "", isCurrent: current)
            guard current(), answer.contains("[1]"), answer.contains("李明"), !summary.isEmpty else { throw NearbyMacFailure.response }
            guard !title.isEmpty, !segment.text.isEmpty else { throw NearbyMacFailure.response }
            self.result = "总结：\n\(summary)\n\n问答：\n\(answer)\n\n标题：\(title)\n\n片段总结：\(segment.text)\n\n每日洞察：\(insight.observation)\n\(insight.nextAction)"
            self.message = "真实 Mac 推理验证通过：总结、问答、标题、片段总结与每日洞察均已返回。"
            // Synthetic text only. No pairing secrets or user records are written to this diagnostic receipt.
            let receipt: [String: Any] = ["passed": true, "created_at": Date().ISO8601Format(), "service_id": configuration.nearbyMacServiceID,
                "model": self.modelID, "summary": summary, "answer": answer, "title": title, "segment_summary": segment.text,
                "insight": ["observation": insight.observation, "nextAction": insight.nextAction],
                "seconds": Date().timeIntervalSince(start), "provider": "nearbyMac"]
            try Self.saveVerification(receipt)
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
    func cancel() { operation?.cancel(); operation = nil; busy = false }
    private static func saveVerification(_ receipt: [String: Any]) throws {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NearbyMacVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
    }
    private func run(diagnostic: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        if diagnostic { result = nil; try? Self.saveVerification(["passed": false, "state": "running", "created_at": Date().ISO8601Format()]) }
        operation = Task {
            defer { self.busy = false; self.operation = nil }
            do { try await body() }
            catch is CancellationError { }
            catch {
                self.message = error.localizedDescription
                if diagnostic { try? Self.saveVerification(["passed": false, "error": error.localizedDescription, "created_at": Date().ISO8601Format()]) }
            }
        }
    }
}

struct NearbyMacVerificationView: View {
    @ObservedObject var model: NearbyMacSettingsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DaybookSheetLayout(title: "Mac 本地模型验证", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("使用固定示例文字测试总结和带引用问答，不读取你的记录。")
                if model.busy { HStack { ProgressView(); Text("正在等待桌面模型返回…") } }
                if let message = model.message { Text(message) }
                if let result = model.result { Text(result).textSelection(.enabled) }
            }.font(.system(size: 14))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsInfo(title: model.name.isEmpty ? "连接附近的 Mac" : model.name,
                text: "配对后，笔记总结、录音标题与 AI 问答使用桌面端当前加载的模型。允许发送的文字经局域网加密传输，音频和照片留在 iPhone。发送前确认偏好继续有效。")
            if !model.serviceID.isEmpty {
                Text("已配对 · \(model.serviceID.prefix(8))").font(.caption).foregroundStyle(DaybookStyle.secondary)
                if !model.modelID.isEmpty { Text(model.modelID).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("检查连接") { model.check() }
                    Button("使用这台 Mac") {
                        var updated = configuration; updated.mode = .nearbyMac
                        updated.nearbyMacServiceID = model.serviceID; updated.nearbyMacName = model.name
                        do { try settings.saveAI(updated, apiKey: ""); configuration = settings.ai }
                        catch { model.show(error: error) }
                    }
                }.buttonStyle(DaybookSettingsButtonStyle()).disabled(model.busy)
                Button("测试连接与总结") { model.verify(settings: settings) }
                    .buttonStyle(DaybookSettingsButtonStyle()).disabled(model.busy)
                    .accessibilityIdentifier("nearbyMac.verify")
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
            if model.busy { HStack { ProgressView(); Text("正在连接 Mac…").font(.caption) } }
            if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).accessibilityIdentifier("nearbyMac.status") }
            if let result = model.result { Text(result).font(.system(size: 13)).textSelection(.enabled).accessibilityIdentifier("nearbyMac.result") }
        }
        .task { model.code = initialCode; await model.restore() }
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
