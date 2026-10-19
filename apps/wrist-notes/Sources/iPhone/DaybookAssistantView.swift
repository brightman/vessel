import SwiftUI

/// Native geometry follows prototype/iphone-day.html and daybook-ai.css.
struct DaybookAssistantView: View {
    let records: [DayRecord]
    let selectedDate: Date
    @ObservedObject var settings: AppSettings
    let allowedKinds: Set<DayRecord.Kind>
    let onOpenRecord: (UUID) -> Void
    let onReminder: (String, UUID) -> Void
    let onPreferences: () -> Void
    let onReminders: () -> Void
    let onDate: () -> Void
    let reminderCount: Int
    let onNewReminder: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = DaybookAssistantModel()
    @State private var question: String
    @State private var submittedQuestion: String?
    @FocusState private var composerFocused: Bool

    init(records: [DayRecord], selectedDate: Date, settings: AppSettings,
         allowedKinds: Set<DayRecord.Kind> = [.voice, .thought, .image], initialQuestion: String = "",
         onOpenRecord: @escaping (UUID) -> Void, onReminder: @escaping (String, UUID) -> Void,
         onPreferences: @escaping () -> Void = {}, onReminders: @escaping () -> Void = {},
         onDate: @escaping () -> Void = {}, reminderCount: Int = 0, onNewReminder: @escaping (String) -> Void = { _ in }) {
        self.records = records; self.selectedDate = selectedDate; self.settings = settings
        self.allowedKinds = allowedKinds; self.onOpenRecord = onOpenRecord; self.onReminder = onReminder
        self.onPreferences = onPreferences; self.onReminders = onReminders; self.onDate = onDate
        self.reminderCount = reminderCount
        self.onNewReminder = onNewReminder
        _question = State(initialValue: initialQuestion)
    }

    private var availableRecords: [DayRecord] {
        records.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDate) && allowedKinds.contains($0.kind) }
    }
    private var activeQuestion: String? { model.prepared?.question ?? submittedQuestion }
    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 300 && !model.isPending
    }
    private var prompts: [String] {
        if availableRecords.isEmpty { return ["这一天有哪些记录？", "明天提醒我做个语音回顾"] }
        return ["这一天最值得跟进什么？", "帮我回顾这一天",
                availableRecords.contains(where: { $0.kind == .image }) ? "这一天的图片记录了什么？" : "这一天有哪些记录？"]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        identity
                        dateContext
                        if activeQuestion == nil { welcome; suggestions }
                        if let activeQuestion { conversation(activeQuestion) }
                        else if let status = model.statusMessage { statusText(status) }
                        liveScopeNote
                        Color.clear.frame(height: 1).id("daybook.ai.bottom")
                    }.padding(.horizontal, 23).padding(.top, 15).padding(.bottom, 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.answer?.id) { _, _ in
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
        .onChange(of: selectedDate) { _, _ in submittedQuestion = nil; synchronize() }
        .onChange(of: allowedKinds) { _, _ in synchronize() }
        .onChange(of: settings.ai) { _, _ in synchronize() }
        .onDisappear { model.cancel() }
        .sheet(item: Binding(get: { model.remoteConfirmation }, set: { if $0 == nil { model.dismissRemoteConfirmation() } })) { confirmation in
            remoteConfirmation(confirmation)
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                DaybookIcon("MessageCircle").foregroundStyle(DaybookStyle.accent)
                    .frame(width: 40, height: 40)
                    .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("WiseNote AI").font(.system(size: 18, weight: .semibold)).tracking(-0.5)
                    Text("懂你的记录，也听你说。").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onPreferences) { DaybookIcon("Settings2", size: 21).frame(width: 40, height: 40) }
                .accessibilityLabel("AI 偏好与提醒设置").accessibilityIdentifier("daybook.assistant.preferences")
        }.padding(.top, 4).padding(.bottom, 18)
    }

    private var dateContext: some View {
        VStack(spacing: 0) {
            DaybookStyle.line.frame(height: 1)
            HStack(spacing: 7) {
                Button(action: onDate) {
                    HStack(spacing: 5) {
                        DaybookIcon("CalendarDays", size: 13)
                        Text("\(dateLabel(selectedDate)) · \(availableRecords.count) 条可用记录")
                            .lineLimit(1).minimumScaleFactor(0.85)
                        DaybookIcon("ChevronDown", size: 13)
                    }.font(.system(size: 10)).padding(.vertical, 5)
                }.accessibilityIdentifier("daybook.assistant.date")
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
            Text("回顾一段对话，串起几个想法，\n或给接下来的一天留一点提醒。")
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
                        Text(prompt).font(.system(size: 12)).lineSpacing(5)
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

    private func conversation(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question).font(.system(size: 13)).lineSpacing(9)
                .foregroundStyle(prototypeColor(0x304b60, dark: DaybookStyle.ink))
                .padding(.vertical, 4)
                .padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
                .background(prototypeColor(0xe9eff4, dark: DaybookStyle.blueSoft),
                            in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 17,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 17))
                .padding(.leading, 30).padding(.bottom, 23)
                .accessibilityIdentifier("daybook.assistant.userMessage")
            if model.isPending {
                HStack(spacing: 8) {
                    DaybookIcon("AudioLines", size: 16)
                    Text("正在整理允许使用的记录…").font(.system(size: 12))
                }.foregroundStyle(DaybookStyle.secondary).padding(.vertical, 8)
            }
            if let answer = model.answer { answerBody(answer) }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.red)
                    .padding(.vertical, 12).accessibilityIdentifier("daybook.assistant.error")
            }
            if let status = model.statusMessage { statusText(status) }
            if let evidence = model.prepared, !model.isPending {
                sourcePills(evidence)
                Text(evidence.scopeDescription).font(.system(size: 10)).lineSpacing(6)
                    .foregroundStyle(DaybookStyle.secondary).padding(.vertical, 12)
                answerActions(evidence)
            } else if !model.isPending && (model.errorMessage != nil || model.statusMessage != nil) { retryButton(question) }
        }.padding(.top, 22).padding(.bottom, 24)
    }

    private func answerBody(_ answer: DaybookAssistantModel.Answer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DaybookIcon("MessageCircle", size: 15); Text("WiseNote AI").font(.system(size: 10))
                Spacer(minLength: 0)
                Text("\(model.prepared.map { dateLabel($0.dayStart) } ?? dateLabel(selectedDate)) · \(answer.generated ? answer.provider : "本地检索")")
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

    private func sourcePills(_ evidence: DaybookRetrieval.Prepared) -> some View {
        DaybookAssistantFlowLayout(spacing: 7) {
            ForEach(evidence.sources) { source in
                Button { onOpenRecord(source.id) } label: {
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
        }.padding(.vertical, evidence.sources.isEmpty ? 0 : 13)
    }

    private func answerActions(_ evidence: DaybookRetrieval.Prepared) -> some View {
        HStack(spacing: 8) {
            if evidence.sources.count == 1, let source = evidence.sources.first {
                Button { remind(from: source) } label: { reminderButtonLabel }.buttonStyle(AssistantSecondaryButtonStyle())
            } else if !evidence.sources.isEmpty {
                Menu { ForEach(evidence.sources) { source in Button(source.title) { remind(from: source) } } } label: { reminderButtonLabel }
                    .buttonStyle(AssistantSecondaryButtonStyle())
            }
            if model.errorMessage != nil || model.statusMessage != nil { retryButton(evidence.question) }
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
        Text(status).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            .padding(.vertical, 12).accessibilityIdentifier("daybook.assistant.status")
    }
    private var liveScopeNote: some View {
        Text("按日期和关键词检索 · 每个问题独立回答\n“今天／昨天”以设备当前日期为准")
            .font(.system(size: 9)).lineSpacing(6).multilineTextAlignment(.center)
            .foregroundStyle(DaybookStyle.secondary).frame(maxWidth: .infinity).padding(.top, 24)
    }

    private var composerDock: some View {
        VStack(spacing: 0) {
            DaybookStyle.line.frame(height: 1)
            VStack(spacing: 7) {
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
                Text(composerHint).font(.system(size: 9)).lineSpacing(5).multilineTextAlignment(.center)
                    .foregroundStyle(question.count > 300 ? DaybookStyle.red : DaybookStyle.secondary).frame(maxWidth: .infinity)
            }.padding(.horizontal, 23).padding(.top, 10).padding(.bottom, 9)
        }.background(DaybookStyle.paper)
    }
    private var composerHint: String {
        if question.count > 300 { return "请把问题缩短到 300 字以内" }
        if model.isPending { return "正在整理允许的记录，可随时停止" }
        return settings.ai.mode == .local ? "仅使用你允许的记录 · Apple 本地模型" : "仅使用你允许的记录 · 发送文字前请你确认"
    }

    private func remoteConfirmation(_ confirmation: DaybookAssistantModel.RemoteConfirmation) -> some View {
        DaybookSheetLayout(title: "发送确认", onClose: { model.dismissRemoteConfirmation() }) {
            VStack(alignment: .leading, spacing: 18) {
                Text("发送本次问题与文字摘录？").font(.system(size: 24, weight: .medium)).lineSpacing(8)
                Text("目标：\(confirmation.destination)").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                Text("将发送下方问题、当天统计和 \(confirmation.sourceCount) 条文字摘录。原始图片和音频保留在本机。")
                    .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.secondary)
                Text("问题").font(.system(size: 13, weight: .medium))
                Text(confirmation.question).font(.system(size: 13)).lineSpacing(7).textSelection(.enabled)
                Text("将发送的全部资料").font(.system(size: 13, weight: .medium))
                HStack(alignment: .top, spacing: 13) {
                    DaybookStyle.accent.opacity(0.5).frame(width: 2)
                    Text(confirmation.context).font(.system(size: 11)).lineSpacing(7)
                        .foregroundStyle(DaybookStyle.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
                Button {
                    model.confirmRemote(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings)
                } label: { Text("确认并发送本次文字") }
                    .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).accessibilityIdentifier("daybook.assistant.confirmRemote")
            }.padding(.top, 12)
        }
    }

    private func submit(_ value: String) {
        guard !model.isPending else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        composerFocused = false; submittedQuestion = value
        model.ask(value, records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings)
        question = ""
    }
    private func remind(from source: DaybookRetrieval.Source) {
        onReminder(source.title.isEmpty ? String(source.snippet.prefix(80)) : source.title, source.id)
    }
    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.defaultDigits).day())
    }
    private func prototypeColor(_ hex: UInt32, dark: Color) -> Color {
        colorScheme == .dark ? dark : Color(red: Double((hex >> 16) & 255) / 255,
                                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private func synchronize() {
        model.synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai)
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
