import SwiftUI

struct ActionProposalView: View {
    let sources: [ActionSource]
    @ObservedObject var store: ActionStore
    @ObservedObject var settings: AppSettings
    let isCurrent: () -> Bool
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ActionItem?
    @State private var pendingConfiguration: AIConfiguration?
    @State private var pendingRevision = 0
    @State private var confirming = false
    @State private var remember = false
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()
    @State private var confirmedZones: [UUID:String] = [:]
    @State private var pendingSources: [ActionSource] = []
    private var effectiveSources: [ActionSource] {
        sources.map { source in
            var value = source
            if let zone = confirmedZones[source.id], !zone.isEmpty { value.timeZoneID = zone; value.timeZoneKnown = true }
            return value
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("从原话到行动") {
                    Text("AI 只生成待确认建议。确认标题、时间和系统关联后，才会安排通知或写入系统。")
                    ForEach(sources,id:\.id) { source in
                        VStack(alignment:.leading,spacing:6) {
                            Text(source.title).font(.headline)
                            Text(source.quote).font(.caption)
                            if !source.timeZoneKnown {
                                Picker("录制时区（核对后可解析相对日期）",selection:Binding(get:{confirmedZones[source.id] ?? ""},set:{confirmedZones[source.id] = $0})) {
                                    Text("暂不确认，时间手动填写").tag("")
                                    Text("当前时区 · \(TimeZone.current.identifier)").tag(TimeZone.current.identifier)
                                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter{$0 != TimeZone.current.identifier},id:\.self) { Text($0).tag($0) }
                                }.disabled(busy)
                            }
                        }
                    }
                }
                Section("手动转为行动") {
                    ForEach(ActionItem.Kind.allCases,id:\.self) { kind in
                        Button("转为\(kind.title)") {
                            guard let source = effectiveSources.first else { return }
                            var item = ActionItem(kind:kind,title:source.title,source:source)
                            item.status = .suggested; editing = item
                        }
                    }
                    if sources.count > 1 { Text("手动创建默认关联第一条来源；AI 可以分别识别各条来源。").font(.caption) }
                }
                Section {
                    Button(busy ? "正在提取建议…" : "用 AI 提取行动建议") {
                        guard isCurrent() else { error = "来源或权限已变化，请重新打开原记录。"; return }
                        pendingConfiguration = settings.ai; pendingRevision = settings.aiRevision; pendingSources = effectiveSources
                        if settings.ai.isRemote && settings.requiresRemoteAIConfirmation { confirming = true }
                        else { generate(confirmed:false) }
                    }.disabled(busy || sources.isEmpty)
                    if busy { Button("停止") { generation = UUID(); task?.cancel(); busy = false } }
                    Text("只分析当前展示的有限摘录。日程结束时间或原始时区不明确时，需要手动补充。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.navigationTitle("转为行动")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(item:$editing) { ActionEditor(store:store,item:$0) }
                .sheet(isPresented:$confirming) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment:.leading,spacing:16) {
                                Text("处理服务：\(pendingConfiguration?.label ?? "")").font(.headline)
                                if let config = pendingConfiguration, config.mode == .custom {
                                    Text("地址：\(URLComponents(string:config.baseURL)?.host ?? "已配置服务")")
                                }
                                Text("处理指令").font(.headline)
                                Text(ActionProposalParser.instruction).font(.caption)
                                Text("发送的原文与时间").font(.headline)
                                Text(ActionProposalParser.content(pendingSources)).font(.caption).textSelection(.enabled)
                                Text("不发送音频文件。发送授权不会自动确认或安排任何行动。").font(.caption)
                                Toggle("下次不再提示",isOn:$remember)
                                Button("确认发送并提取建议") { confirming = false; generate(confirmed:true) }.buttonStyle(.borderedProminent)
                            }.padding()
                        }.navigationTitle("发送前确认")
                            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { confirming = false } } }
                    }
                }
                .onDisappear { generation = UUID(); task?.cancel() }
        }
    }
    private func generate(confirmed: Bool) {
        guard let configuration = pendingConfiguration, configuration == settings.ai, pendingRevision == settings.aiRevision, pendingSources == effectiveSources, isCurrent() else { error = "模型、来源或权限已变化，请重新提取。"; return }
        busy = true; error = nil
        let revision = pendingRevision
        let requestSources = pendingSources
        let token = UUID(); generation = token
        task = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                var key: String?
                if configuration.isRemote {
                    if configuration.mode == .custom {
                        let secret = try settings.apiKey(); key = secret
                        _ = try configuration.validated(apiKey:secret)
                    } else {
                        guard settings.chatGPT.isReady, settings.chatGPT.selectedID == configuration.chatGPTAccountID else { throw ActionFailure.invalid("请先连接 ChatGPT。") }
                    }
                    guard settings.authorizeRemoteAISend(confirmationIsCurrent:confirmed ? true : nil,rememberChoice:confirmed && remember) else { throw ActionFailure.changed }
                }
                let values = try await ActionProposalService().generate(sources:requestSources,configuration:configuration,apiKey:key,isCurrent:{
                    generation == token && requestSources == effectiveSources && isCurrent() && settings.ai == configuration && settings.aiRevision == revision
                })
                try Task.checkCancellation()
                guard generation == token && isCurrent() else { throw ActionFailure.changed }
                if values.isEmpty { error = "原文中没有找到明确的行动意图。"; return }
                if store.addSuggestions(values) { onFinished() }
                else { error = store.error ?? "未能保存行动建议，请重试。" }
            } catch is CancellationError { if generation == token { error = "已停止，没有新增行动。" } }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}
