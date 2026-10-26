import SwiftUI

/// Native geometry follows prototype/iphone-day.html and daybook-ai.css.
struct DaybookAssistantView: View {
    let records: [DayRecord]
    let selectedDate: Date
    @ObservedObject var settings: AppSettings
    let allowedKinds: Set<DayRecord.Kind>
    let onOpenRecord: (UUID) -> Void
    var onOpenCitation: ((DaybookRetrieval.Source) -> Void)?
    let onReminder: (String, UUID) -> Void
    let onPreferences: () -> Void
    let onReminders: () -> Void
    let reminderCount: Int
    let onNewReminder: (String) -> Void
    var onActions: ([DaybookRetrieval.Source]) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: DaybookAssistantModel
    @State private var confirmingReset = false
    @State private var confirmingClear = false
    @State private var showAISettings = false
    @State private var question: String
    @FocusState private var composerFocused: Bool

    init(model: DaybookAssistantModel, records: [DayRecord], selectedDate: Date, settings: AppSettings,
         allowedKinds: Set<DayRecord.Kind> = [.voice, .thought, .image], initialQuestion: String = "",
         onOpenRecord: @escaping (UUID) -> Void, onReminder: @escaping (String, UUID) -> Void,
         onPreferences: @escaping () -> Void = {}, onReminders: @escaping () -> Void = {},
         reminderCount: Int = 0, onNewReminder: @escaping (String) -> Void = { _ in }, onOpenCitation: ((DaybookRetrieval.Source) -> Void)? = nil, onActions: @escaping ([DaybookRetrieval.Source]) -> Void = { _ in }) {
        self.onActions = onActions
        self.onOpenCitation = onOpenCitation
        self.model = model
        self.records = records; self.selectedDate = selectedDate; self.settings = settings
        self.allowedKinds = allowedKinds; self.onOpenRecord = onOpenRecord; self.onReminder = onReminder
        self.onPreferences = onPreferences; self.onReminders = onReminders
        self.reminderCount = reminderCount
        self.onNewReminder = onNewReminder
        _question = State(initialValue: initialQuestion)
    }

    private var displayedTurns: [DaybookAssistantModel.Answer] {
        model.validatedTurns(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds)
    }
    private var activeEvidence: DaybookRetrieval.Prepared? {
        guard model.isSynchronized(selectedDate: selectedDate), let evidence = model.prepared, evidence.isCurrent(records: model.recordsForEvidence(records), allowedKinds: allowedKinds) else { return nil }
        return evidence
    }
    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 300 && !model.isPending && model.storageError == nil
    }
    private var prompts: [String] {
        ["昨天有哪些值得跟进的事？", "我之前记下过哪些想法？", "最近的睡眠有什么变化？"]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        identity
                        retrievalContext
                        storageNotice
                        if model.hasMoreHistory {
                            Button("加载更早的 10 轮对话") { model.loadMoreHistory() }
                                .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                                .accessibilityIdentifier("daybook.assistant.loadEarlier")
                        }
                        if displayedTurns.isEmpty { welcome; suggestions }
                        ForEach(displayedTurns) { turn in
                            VStack(alignment: .leading, spacing: 0) {
                                if let sentAt = turn.createdAt {
                                    Text(sentAt.formatted(.dateTime.month().day().hour().minute()))
                                        .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                                        .frame(maxWidth: .infinity).padding(.bottom, 15)
                                }
                                userMessage(turn.question)
                                if turn.completionState == .completed {
                                    answerBody(turn)
                                    if turn.evidence.isCurrent(records: model.recordsForEvidence(records), allowedKinds: allowedKinds) {
                                        sourcePills(turn.sources)
                                        Text(turn.scopeDescription).font(.system(size: 10)).lineSpacing(6)
                                            .foregroundStyle(DaybookStyle.secondary).padding(.vertical, 12)
                                        answerActions(sources: turn.sources, question: turn.question, canRetry: false)
                                    } else {
                                        statusText("这是当时的回答。相关资料已变化，可重新提问获取最新结果。")
                                        retryButton(turn.question)
                                    }
                                } else if turn.completionState == .pending {
                                    statusText(model.storageError != nil ? "本次更改尚未保存，请重试保存。" : model.remoteConfirmation != nil ? "等待确认发送本次文字。" : model.retrievalStatus)
                                } else {
                                    statusText(turn.text)
                                    if turn.id == model.preparedTurnID, let evidence = activeEvidence {
                                        sourcePills(evidence.sources)
                                        Text(evidence.scopeDescription).font(.system(size: 10)).lineSpacing(6)
                                            .foregroundStyle(DaybookStyle.secondary).padding(.vertical, 12)
                                        answerActions(sources: evidence.sources, question: turn.question, canRetry: false)
                                    }
                                    retryButton(turn.question)
                                }
                            }.padding(.top, 22).padding(.bottom, 24).id(turn.id)
                        }
                        if let error = model.errorMessage { Text(LocalizedStringKey(error)).font(.system(size: 12)).foregroundStyle(DaybookStyle.red) }
                        if let status = model.statusMessage { statusText(status) }
                        liveScopeNote
                        Color.clear.frame(height: 1).id("daybook.ai.bottom")
                    }.padding(.horizontal, 23).padding(.top, 15).padding(.bottom, 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        let anchor = displayedTurns.first?.id
                        model.loadMoreHistory()
                        await Task.yield()
                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                    }
                    .onAppear { proxy.scrollTo("daybook.ai.bottom", anchor: .bottom) }
                    .onChange(of: model.answer?.id) { _, _ in
                        if let answer = model.answer, question == answer.question { question = "" }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("daybook.ai.bottom", anchor: .bottom) }
                    }
                    .onChange(of: model.isPending) { _, pending in
                        if pending { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("daybook.ai.bottom", anchor: .bottom) } }
                    }
            }
            composerDock
        }
        .background(DaybookStyle.paper).foregroundStyle(DaybookStyle.ink)
        .tint(DaybookStyle.accent).buttonStyle(.plain)
        .onAppear { synchronize() }
        .onChange(of: records) { _, _ in synchronize() }
        .onChange(of: selectedDate) { _, _ in synchronize() }
        .onChange(of: allowedKinds) { _, _ in synchronize() }
        .onChange(of: settings.ai) { _, _ in synchronize() }
        .onChange(of: settings.aiRevision) { _, _ in synchronize() }
        .onDisappear { model.cancel() }
        .confirmationDialog("重置所有本机对话存储？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("重置所有本机对话", role: .destructive) { model.resetStorage() }
        }
        .confirmationDialog("清除全部对话历史？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除全部对话", role: .destructive) { model.clearHistory() }
        }
        .sheet(item: Binding(get: { activeEvidence == nil ? nil : model.remoteConfirmation }, set: { if $0 == nil { model.dismissRemoteConfirmation() } })) { confirmation in
            remoteConfirmation(confirmation)
        }
        .sheet(isPresented: $showAISettings) { AISettingsView(settings: settings) }
    }

    @ViewBuilder private var storageNotice: some View {
        if let error = model.storageError {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(error)).font(.system(size: 12)).foregroundStyle(DaybookStyle.red)
                Button(LocalizedStringKey(model.needsStorageReset ? "重试读取" : "重试保存")) { model.retryPersistence() }
                if model.needsStorageReset { Button("重置所有本机对话…", role: .destructive) { confirmingReset = true } }
            }.font(.system(size: 12)).padding(.vertical, 12)
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                DaybookIcon("MessageCircle").foregroundStyle(DaybookStyle.accent)
                    .frame(width: 40, height: 40)
                    .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("WiseLife AI").font(.system(size: 18, weight: .semibold)).tracking(-0.5)
                    Text("懂你的记录，也听你说。").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("清除全部对话…", role: .destructive) { confirmingClear = true }
                Button("AI 偏好与提醒设置", action: onPreferences)
            } label: { DaybookIcon("MoreHorizontal", size: 21).frame(width: 36, height: 40) }
                .accessibilityLabel("对话操作")
            Button(action: onPreferences) { DaybookIcon("Settings2", size: 21).frame(width: 40, height: 40) }
                .accessibilityLabel("AI 偏好与提醒设置").accessibilityIdentifier("daybook.assistant.preferences")
        }.padding(.top, 4).padding(.bottom, 18)
    }

    private var retrievalContext: some View {
        VStack(spacing: 0) {
            DaybookStyle.line.frame(height: 1)
            HStack(spacing: 7) {
                Text("按问题查找相关记录")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                    .accessibilityIdentifier("daybook.assistant.retrievalContext")
                Spacer(minLength: 0)
                Button(action: onReminders) {
                    HStack(spacing: 3) {
                        DaybookIcon("Bell", size: 13); Text("提醒")
                        Text("\(max(0, reminderCount))").monospacedDigit().foregroundStyle(DaybookStyle.accent)
                            .frame(minWidth: 17, minHeight: 17).background(DaybookStyle.blueSoft, in: Circle())
                    }.font(.system(size: 10)).padding(.vertical, 5)
                }.accessibilityLabel("提醒，\(max(0, reminderCount)) 条未完成")
                    .accessibilityIdentifier("daybook.assistant.reminders")
            }.foregroundStyle(DaybookStyle.secondary).padding(.vertical, 9)
            DaybookStyle.line.frame(height: 1)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("从你的生活里，找到答案").font(.system(size: 11, weight: .medium))
                .tracking(0.4).foregroundStyle(DaybookStyle.secondary)
            Text("今天，有什么\n想一起理一理？").font(.system(size: 29, weight: .medium))
                .tracking(-1).lineSpacing(9).frame(height: 87, alignment: .leading).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
            Text("直接说你想知道什么。\n我会从你允许的记录里寻找线索。")
                .font(.system(size: 12)).lineSpacing(8).frame(height: 46, alignment: .leading)
                .foregroundStyle(DaybookStyle.secondary)
        }.padding(.top, 29).padding(.bottom, 25)
    }

    private var suggestions: some View {
        VStack(spacing: 8) {
            ForEach(prompts, id: \.self) { prompt in
                Button {
                    if prompt == "明天提醒我做个语音回顾" { onNewReminder("做个语音回顾") } else { submit(prompt) }
                } label: {
                    HStack(spacing: 12) {
                        Text(LocalizedStringKey(prompt)).font(.system(size: 12)).lineSpacing(5)
                        Spacer(minLength: 0)
                        DaybookIcon("ArrowUpRight", size: 14).foregroundStyle(DaybookStyle.secondary)
                    }.frame(minHeight: 21).padding(.horizontal, 13).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(DaybookStyle.line, lineWidth: 1))
                }.disabled(model.isPending)
            }
        }.padding(.top, 15).padding(.bottom, 23).accessibilityLabel("可以这样问")
    }

    private func userMessage(_ question: String) -> some View {
            Text(question).font(.system(size: 13)).lineSpacing(9)
                .foregroundStyle(prototypeColor(0x304b60, dark: DaybookStyle.ink))
                .padding(.vertical, 4)
                .padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
                .background(prototypeColor(0xe9eff4, dark: DaybookStyle.blueSoft),
                            in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 17,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 17))
                .padding(.leading, 30).padding(.bottom, 23)
                .accessibilityIdentifier("daybook.assistant.userMessage")
    }

    private func answerBody(_ answer: DaybookAssistantModel.Answer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DaybookIcon("MessageCircle", size: 15); Text("WiseLife AI").font(.system(size: 10))
                Spacer(minLength: 0)
                Text("\(answer.generated ? answer.provider : "本地检索")")
                    .font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary).lineLimit(1)
            }.foregroundStyle(DaybookStyle.accent).padding(.bottom, 12)
            // Preserve provider text verbatim; generated links never become trusted actions.
            Text(answer.text).font(.system(size: 13)).lineSpacing(10)
                .foregroundStyle(prototypeColor(0x435460, dark: DaybookStyle.ink))
                .padding(.vertical, 5).padding(.bottom, 12)
                .textSelection(.enabled).accessibilityIdentifier("daybook.assistant.answer")
            if answer.generated {
                Text("请结合原文核对，摘录可能不完整。").font(.system(size: 10))
                    .foregroundStyle(DaybookStyle.secondary).padding(.top, 12)
            }
        }
    }

    private func sourcePills(_ sources: [DaybookRetrieval.Source]) -> some View {
        DaybookAssistantFlowLayout(spacing: 7) {
            ForEach(sources) { source in
                Button { if let onOpenCitation { onOpenCitation(source) } else { onOpenRecord(source.id) } } label: {
                    HStack(spacing: 6) {
                        DaybookIcon("Link2", size: 12)
                        Text("[\(source.number)] \(dateLabel(source.capturedAt)) \(source.capturedAt.formatted(.dateTime.hour().minute())) · \(source.title.isEmpty ? DaybookRetrieval.kindLabel(source.kind) : source.title)")
                            .font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 235, alignment: .leading)
                        DaybookIcon("ArrowUpRight", size: 12)
                    }.frame(minHeight: 18).foregroundStyle(DaybookStyle.accent)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prototypeColor(0xdae3ea, dark: DaybookStyle.line), lineWidth: 1))
                }.contextMenu { Button("从这条记录添加提醒") { remind(from: source) } }
                    .accessibilityLabel("来源 \(source.number)，\(source.title)，打开原始记录")
            }
        }.padding(.vertical, sources.isEmpty ? 0 : 13)
    }

    private func answerActions(sources: [DaybookRetrieval.Source], question: String, canRetry: Bool) -> some View {
        HStack(spacing: 8) {
            if !sources.isEmpty { Button("加入行动") { onActions(sources) }.buttonStyle(AssistantSecondaryButtonStyle()) }
            if sources.count == 1, let source = sources.first {
                Button { remind(from: source) } label: { reminderButtonLabel }.buttonStyle(AssistantSecondaryButtonStyle())
            } else if !sources.isEmpty {
                Menu { ForEach(sources) { source in Button(source.title) { remind(from: source) } } } label: { reminderButtonLabel }
                    .buttonStyle(AssistantSecondaryButtonStyle())
            }
            if canRetry { retryButton(question) }
        }.padding(.top, 13)
    }

    private var reminderButtonLabel: some View {
        HStack(spacing: 7) { DaybookIcon("Bell", size: 15); Text("设一个提醒") }
    }
    private func retryButton(_ question: String) -> some View {
        Button { submit(question) } label: {
            HStack(spacing: 7) { DaybookIcon("RotateCcw", size: 15); Text("重新回答") }
        }.buttonStyle(AssistantSecondaryButtonStyle())
    }
    private func statusText(_ status: String) -> some View {
        Text(LocalizedStringKey(status)).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            .padding(.vertical, 12).accessibilityIdentifier("daybook.assistant.status")
    }
    private var liveScopeNote: some View {
        Text("历史保存在本机 · 按问题查找获准使用的记录\n可以追问「只看上周」或「再往前找找」")
            .font(.system(size: 9)).lineSpacing(6).multilineTextAlignment(.center)
            .foregroundStyle(DaybookStyle.secondary).frame(maxWidth: .infinity).padding(.top, 24)
    }

    private var composerDock: some View {
        VStack(spacing: 0) {
            DaybookStyle.line.frame(height: 1)
            VStack(spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
                    Button { showAISettings = true } label: {
                        HStack(spacing: 5) {
                            DaybookIcon(settings.ai.isRemote ? "MessageCircle" : "ShieldCheck", size: 13)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(settings.ai.label).lineLimit(1)
                                if settings.ai.mode == .chatgpt {
                                    Text(settings.chatGPT.isReady ? "使用 ChatGPT 套餐" : "ChatGPT 当前不可用")
                                        .font(.system(size: 9))
                                }
                            }
                            DaybookIcon("ChevronDown", size: 12)
                        }.font(.system(size: 10))
                    }.accessibilityIdentifier("daybook.assistant.models")
                    Spacer(minLength: 0)
                    if settings.ai.mode == .chatgpt {
                        Link("管理用量 ↗", destination: ChatGPTAccountModel.usageURL).font(.system(size: 10))
                    }
                }.foregroundStyle(DaybookStyle.secondary).padding(.bottom, 2)
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("问问自己的记录…", text: $question, axis: .vertical)
                        .font(.system(size: 16)).lineSpacing(5).lineLimit(1...4)
                        .frame(minHeight: 29).padding(.vertical, 3).focused($composerFocused)
                        .accessibilityLabel("问问自己的记录").accessibilityIdentifier("daybook.assistant.question")
                    Button {
                        if model.isPending { model.cancel() } else { submit(question) }
                    } label: {
                        DaybookIcon(model.isPending ? "Square" : "ArrowUp", size: 17)
                            .foregroundStyle(canSubmit || model.isPending ? DaybookStyle.white : prototypeColor(0x37556b, dark: DaybookStyle.secondary))
                            .frame(width: 31, height: 31)
                            .background(canSubmit || model.isPending ? DaybookStyle.accent : prototypeColor(0xc8d4df, dark: DaybookStyle.field), in: Circle())
                    }.disabled(!model.isPending && !canSubmit)
                        .accessibilityLabel(model.isPending ? "停止回答" : "发送问题")
                        .accessibilityIdentifier(model.isPending ? "daybook.assistant.stop" : "daybook.assistant.submit")
                }.padding(.leading, 13).padding(.trailing, 8).padding(.vertical, 8)
                    .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 19))
                    .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(prototypeColor(0xccd8e1, dark: DaybookStyle.line), lineWidth: 1))
                Text(LocalizedStringKey(composerHint)).font(.system(size: 9)).lineSpacing(5).multilineTextAlignment(.center)
                    .foregroundStyle(question.count > 300 ? DaybookStyle.red : DaybookStyle.secondary).frame(maxWidth: .infinity)
            }.padding(.horizontal, 23).padding(.top, 10).padding(.bottom, 9)
        }.background(DaybookStyle.paper)
    }
    private var composerHint: String {
        if question.count > 300 { return "请把问题缩短到 300 字以内" }
        if model.isPending { return "正在整理允许的记录，可随时停止" }
        if settings.ai.mode == .local { return "仅使用你允许的记录 · Apple Intelligence" }
        return settings.requiresRemoteAIConfirmation ? "仅使用你允许的记录 · 发送文字前请你确认" : "仅使用你允许的记录 · 发送给所选外部 AI"
    }

    private func remoteConfirmation(_ confirmation: DaybookAssistantModel.RemoteConfirmation) -> some View {
        DaybookSheetLayout(title: "发送确认", onClose: { model.dismissRemoteConfirmation() }) {
            VStack(alignment: .leading, spacing: 18) {
                Text("发送本次问题与文字摘录？").font(.system(size: 24, weight: .medium)).lineSpacing(8)
                Text("目标：\(confirmation.destination)").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                Text("将发送下方问题、有限先前对话、当天统计和 \(confirmation.sourceCount) 条文字摘录。原始图片和音频保留在本机。")
                    .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.secondary)
                Text("模型指令").font(.system(size: 13, weight: .medium))
                Text(confirmation.instruction).font(.system(size: 11)).lineSpacing(7).textSelection(.enabled)
                Text("将发送的全部资料").font(.system(size: 13, weight: .medium))
                HStack(alignment: .top, spacing: 13) {
                    DaybookStyle.accent.opacity(0.5).frame(width: 2)
                    Text(confirmation.message).font(.system(size: 11)).lineSpacing(7)
                        .foregroundStyle(DaybookStyle.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
                RemoteAISendControls(buttonTitle: "确认并发送本次文字", accessibilityID: "daybook.assistant.confirmRemote") { doNotAskAgain in
                    model.confirmRemote(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings, doNotAskAgain: doNotAskAgain)
                    if model.isPending && question == confirmation.question { question = "" }
                }.id(confirmation.id)
            }.padding(.top, 12)
        }
    }

    private func submit(_ value: String) {
        guard !model.isPending else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        composerFocused = false
        model.ask(value, records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings)
        // Retain the user's draft until a remote confirmation or successful local answer.
    }
    private func remind(from source: DaybookRetrieval.Source) {
        onReminder(source.title.isEmpty ? String(source.snippet.prefix(80)) : source.title, source.id)
    }
    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.locale(settings.interfaceLanguage.locale).month(.defaultDigits).day())
    }
    private func prototypeColor(_ hex: UInt32, dark: Color) -> Color {
        colorScheme == .dark ? dark : Color(red: Double((hex >> 16) & 255) / 255,
                                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private func synchronize() {
        model.synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
    }
}

private struct AssistantSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(DaybookStyle.blueSoft.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// CSS flex-wrap equivalent for compact source pills, with no horizontal overflow.
private struct DaybookAssistantFlowLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 350, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: frames.isEmpty ? 0 : y + rowHeight), frames)
    }
}
