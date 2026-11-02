import SwiftUI

struct FlashNotebookView: View {
    @EnvironmentObject private var flash: FlashCaptureModel
    @State var kind: FlashAsset.Kind = .idea
    let onClose: () -> Void
    let onOpenSource: (UUID) -> Void
    @State private var pendingOnly = false
    @State private var showRevoked = false
    @State private var selected: FlashAsset?
    private var rows: [FlashAsset] {
        flash.assets.filter { $0.kind == kind && (showRevoked || !$0.revoked) && (!pendingOnly || !$0.ready) }
    }
    var body: some View {
        DaybookSheetLayout(title: "记事本", onClose: onClose) {
            VStack(alignment: .leading, spacing: 18) {
                Picker("记事本", selection: $kind) {
                    ForEach(FlashAsset.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("notebook.tabs")
                if kind == .expense {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("全部日期 · 按币种汇总").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                        ForEach(flash.totals, id: \.currency) { total in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(total.currency).font(.system(size: 12, weight: .semibold))
                                Text("收入 \(FlashMoney.decimalString(total.income, currency: total.currency)) · 支出 \(FlashMoney.decimalString(total.expense, currency: total.currency))").font(.system(size: 14))
                            }
                        }
                        Toggle("只看待补充", isOn: $pendingOnly).font(.system(size: 12))
                        Text("待补充与已撤销账目不计入汇总。").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                    }.daybookRecordingCard(padding: 14)
                }
                if rows.isEmpty { DaybookQuietInfo(text: kind == .idea ? "还没有想法。录下一条闪念，整理后会保存在这里。" : "还没有符合条件的账目。") }
                LazyVStack(spacing: 0) {
                    ForEach(rows) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                if kind == .idea {
                                    Text(item.text).font(.system(size: 14)).lineSpacing(5).foregroundStyle(DaybookStyle.ink)
                                } else {
                                    HStack { Text(item.title); Spacer(); Text(item.amountText).monospacedDigit() }
                                        .font(.system(size: 14, weight: .medium))
                                    Text("\(item.category ?? "未分类") · \(item.date ?? "日期待补充") · \(item.statusTitle)")
                                        .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                                }
                                Text(RecordingFormat.date(item.source.capturedAt) + (item.revoked ? " · 已撤销" : ""))
                                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                                .overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 0.5) }
                        }.buttonStyle(.plain)
                    }
                }
                Toggle("显示已撤销", isOn: $showRevoked).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                if let error = flash.error { Text(error).font(.caption).foregroundStyle(DaybookStyle.red) }
            }.padding(.top, 12)
        }
        .onAppear { flash.reload() }
        .onChange(of: kind) { _, _ in pendingOnly = false }
        .sheet(item: $selected) { item in
            FlashAssetDetailView(id: item.id, onOpenSource: { id in selected = nil; onOpenSource(id) })
        }
    }
}

struct FlashAssetDetailView: View {
    @EnvironmentObject private var flash: FlashCaptureModel
    @EnvironmentObject private var notes: NotesModel
    @EnvironmentObject private var actions: ActionStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let onOpenSource: (UUID) -> Void
    @State private var editing: FlashAsset?
    @State private var newAction: ActionItem?
    private var item: FlashAsset? { flash.assets.first { $0.id == id } }
    var body: some View {
        DaybookSheetLayout(title: item?.kind == .idea ? "想法" : "账目", onClose: { dismiss() }) {
            if let item {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.title).font(.system(size: 20, weight: .semibold))
                    if item.kind == .expense { Text(item.amountText).font(.system(size: 24, weight: .semibold)) }
                    Text(item.text).font(.system(size: 14)).lineSpacing(7)
                    Text("\(RecordingFormat.date(item.source.capturedAt)) · \(item.statusTitle)").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                    HStack(spacing: 24) {
                        Button(item.ready ? "编辑" : "补充信息") { editing = item }
                        Button(item.revoked ? "恢复" : "撤销") { flash.toggle(item) }
                    }.font(.system(size: 13, weight: .medium)).foregroundStyle(DaybookStyle.accent)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原话").font(.system(size: 12, weight: .medium))
                        if let device = item.source.device { Text(device).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary) }
                        Text(item.source.quote).font(.system(size: 13)).lineSpacing(6)
                        if notes.note(item.source.id) != nil {
                            Button("查看来源录音") { onOpenSource(item.source.id) }
                        } else { Text("原始录音已删除；保存的原话仍保留。").foregroundStyle(DaybookStyle.secondary) }
                    }.font(.system(size: 12)).daybookRecordingCard(padding: 14)
                    if item.kind == .idea {
                        Button("创建行动") { newAction = ActionItem(kind: .todo, title: item.title, notes: item.text, source: item.source) }
                            .font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                    }
                    if let error = flash.error { Text(error).font(.caption).foregroundStyle(DaybookStyle.red) }
                }.padding(.top, 12)
            }
        }.sheet(item: $editing) { FlashAssetEditor(item: $0) }
            .sheet(item: $newAction) { ActionEditor(store: actions, item: $0, isNew: true) }
    }
}

private struct FlashAssetEditor: View {
    @EnvironmentObject private var flash: FlashCaptureModel
    @Environment(\.dismiss) private var dismiss
    @State var item: FlashAsset
    @State private var amount = ""
    @State private var currency = ""
    @State private var date = ""
    @State private var error: String?
    var body: some View {
        DaybookSheetLayout(title: item.kind == .idea ? "编辑想法" : "编辑账目", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                DaybookSettingsField("标题") { TextField("标题", text: $item.title) }
                DaybookSettingsField("内容") { TextField("内容", text: $item.text, axis: .vertical).lineLimit(3...10) }
                if item.kind == .expense {
                    DaybookSettingsField("收支") {
                        Picker("收支", selection: $item.direction) {
                            Text("待补充").tag(Optional<FlashAsset.Direction>.none)
                            Text("支出").tag(Optional(FlashAsset.Direction.expense)); Text("收入").tag(Optional(FlashAsset.Direction.income))
                        }.pickerStyle(.segmented)
                    }
                    DaybookSettingsField("金额") { TextField("待补充", text: $amount).keyboardType(.decimalPad) }
                    DaybookSettingsField("币种") { TextField("CNY / USD / JPY", text: $currency).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                    DaybookSettingsField("类别") { TextField("未分类", text: Binding(get: { item.category ?? "" }, set: { item.category = $0 })) }
                    DaybookSettingsField("日期") { TextField("yyyy-MM-dd", text: $date).keyboardType(.numbersAndPunctuation) }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(DaybookStyle.red) }
                DaybookSettingsActions(cancel: { dismiss() }, save: save, canSave: !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 12)
        }.onAppear {
            currency = item.currency ?? ""; date = item.date ?? ""
            amount = item.amountMinor.map { FlashMoney.decimalString($0, currency: currency) } ?? ""
        }
    }
    private func save() {
        do {
            var value = item
            if value.kind == .expense {
                let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                value.currency = code.isEmpty ? nil : code
                value.amountMinor = amount.isEmpty || code.isEmpty ? nil : try FlashMoney.minorUnits(amount, currency: code)
                value.date = date.isEmpty ? nil : date
            }
            if flash.save(value) { dismiss() } else { error = flash.error }
        } catch { self.error = error.localizedDescription }
    }
}

struct FlashOrganizedView: View {
    @EnvironmentObject private var flash: FlashCaptureModel
    @EnvironmentObject private var actions: ActionStore
    @EnvironmentObject private var notes: NotesModel
    @EnvironmentObject private var settings: AppSettings
    let note: VoiceNote
    @State private var selectedAsset: FlashAsset?
    @State private var selectedAction: ActionItem?
    @State private var notebook: FlashAsset.Kind?
    @State private var remote: NotesModel.RemoteSummaryRequest?
    @State private var sourceToOpen: UUID?
    @State private var sourceNote: VoiceNote?
    private var assets: [FlashAsset] { flash.assets.filter { $0.source.id == note.id } }
    private var commands: [ActionItem] { actions.flashTimelineItems.filter { $0.source?.id == note.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if flash.processing.contains(note.id) { ProgressView("正在整理闪念…") }
            else if flash.batches[note.id]?.state == .complete {
                Text(assets.isEmpty && commands.isEmpty ? "这次，留住原话就好。" : "已整理 \(assets.count + commands.count) 项")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text(flash.batches[note.id]?.message ?? (note.transcript.isEmpty ? "等待语音转写，原音频已保存。" : "将闪念整理为想法、账目和明确指令。"))
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                if flash.batches[note.id]?.state == .historical { Text("历史闪念只提取内容，行动需编辑后保存安排。").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary) }
                Button("整理闪念") { request() }.disabled(note.transcript.isEmpty).font(.system(size: 13)).foregroundStyle(DaybookStyle.accent)
            }
            ForEach(assets) { asset in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(asset.kind == .idea ? "想法" : "账目"); Spacer(); Text(asset.statusTitle).foregroundStyle(DaybookStyle.secondary) }.font(.system(size: 11))
                    Text(asset.title).font(.system(size: 14, weight: .semibold))
                    Text(asset.kind == .idea ? asset.text : asset.amountText).font(.system(size: 14)).lineSpacing(5)
                    HStack(spacing: 20) {
                        Button(asset.ready ? "编辑 / 原话" : "补充信息") { selectedAsset = asset }
                        Button(asset.revoked ? "恢复" : "撤销") { flash.toggle(asset) }
                    }.font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                }.daybookRecordingCard(padding: 14)
            }
            ForEach(commands) { item in
                Button { selectedAction = item } label: { FlashCommandRow(item: item) }
                    .buttonStyle(.plain).daybookRecordingCard(padding: 14)
            }
            Text("原音频与全文保留在本机。删除录音不会删除已保存的想法、账目或行动。").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            HStack(spacing: 20) {
                Button("我的想法") { notebook = .idea }; Button("我的记账") { notebook = .expense }
            }.font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
        }
        .sheet(item: $selectedAsset) { FlashAssetDetailView(id: $0.id, onOpenSource: { _ in selectedAsset = nil }) }
        .sheet(item: $selectedAction) { item in
            FlashActionDetailView(store: actions, id: item.id, onOpenSource: { _ in selectedAction = nil }, onClose: { selectedAction = nil })
        }
        .sheet(isPresented: Binding(get: { notebook != nil }, set: { if !$0 { notebook = nil } }), onDismiss: {
            if let id = sourceToOpen { sourceToOpen = nil; if id != note.id { sourceNote = notes.note(id) } }
        }) {
            FlashNotebookView(kind: notebook ?? .idea, onClose: { notebook = nil }, onOpenSource: { id in sourceToOpen = id; notebook = nil })
        }
        .sheet(item: $sourceNote) { DaybookVoiceDetailView(id: $0.id) }
        .sheet(item: $remote) { request in
            RemoteSummaryConfirmationView(request: request, onCancel: { remote = nil }, onConfirm: { remember in
                remote = nil
                guard let current = notes.note(note.id), current.transcript == request.text,
                      settings.aiRevision == request.revision, notes.summaryConfiguration(for: current) == request.configuration else { return }
                Task { await flash.process(current, confirmation: request, remember: remember) }
            }, isFlash: true)
        }
    }
    private func request() {
        if notes.summaryConfiguration(for: note).isRemote && settings.requiresRemoteAIConfirmation { remote = notes.prepareRemoteSummary(note.id) }
        else { Task { await flash.process(note) } }
    }
}
