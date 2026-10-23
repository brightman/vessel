import SwiftUI

struct DaybookInsightView: View {
    @ObservedObject var model: DaybookInsightModel
    let records: [DayRecord]
    let selectedDate: Date
    let allowedKinds: Set<DayRecord.Kind>
    let language: String
    let onOpenRecord: (UUID) -> Void
    @State private var confirmingReset = false
    let onReminder: (String, UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                DaybookIcon("Lightbulb", size: 15)
                Text("每日洞察 · \(model.providerLabel)").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(DaybookStyle.accent)
            Text(selectedDate.formatted(.dateTime.locale(Locale(identifier: language)).year().month().day())).font(.caption).foregroundStyle(DaybookStyle.secondary)
            if let storageError = model.storageError {
                Text(storageError).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                Button("重试读取洞察") { model.retryStorage() }.font(.caption)
                Button("重置本机洞察存储", role: .destructive) { confirmingReset = true }.font(.caption)
            } else if let insight = model.currentResult(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, language: language) {
                Text(insight.output.observation).font(.system(size: 15, weight: .medium)).lineSpacing(6).textSelection(.enabled)
                Text(insight.output.nextAction).font(.system(size: 12)).lineSpacing(5)
                ForEach(insight.sources) { source in
                    Button { onOpenRecord(source.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("[\(source.number)] \(source.title)"); Spacer(); DaybookIcon("ChevronRight", size: 12) }
                            Text(source.snippet).foregroundStyle(DaybookStyle.secondary)
                            if source.truncated { Text("摘录已截断，请打开原记录核对。").foregroundStyle(DaybookStyle.secondary) }
                        }.font(.system(size: 10)).padding(.vertical, 5)
                    }
                }
                Button {
                    onReminder(insight.output.reminderTitle, insight.sources.first { insight.output.nextAction.contains("[\($0.number)]") }?.id)
                } label: { Text("将建议带入提醒草稿") }.buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                Text("仅填写草稿；标题和时间由你确认后才安排提醒。").font(.caption).foregroundStyle(DaybookStyle.secondary)
                Button("不符合我的情况") { model.dismiss() }.font(.caption).foregroundStyle(DaybookStyle.secondary)
            } else if model.isPending {
                HStack { ProgressView(); Text(model.usesRemoteProvider ? "正在由所选 AI 综合多条记录…" : "正在本机综合多条记录…").font(.system(size: 12)) }
            } else if let message = model.message {
                Text(LocalizedStringKey(message)).font(.system(size: 12)).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
            } else {
                Text(model.isDismissed ? "已收起这组来源的洞察。来源变化后可重新分析。" : model.hasEnoughSources ? "根据允许的原文生成一条观察和一个小行动。" : "至少需要两条有文字的允许来源，才能生成每日洞察。")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
            }
            if model.isPending { Button("取消生成") { model.cancel() }.font(.caption) }
            else {
                Button { model.refresh() } label: { Text("生成 / 刷新洞察") }
                    .font(.system(size: 12, weight: .medium)).disabled(!model.hasEnoughSources || model.storageError != nil)
            }
            Text(model.usesRemoteProvider ? "使用所选外部 AI，仅发送允许来源的文字摘录。AI 观察可能有误，请核对来源。" : "仅在本机分析。AI 观察可能有误，请核对来源。")
                .font(.system(size: 10)).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
        }.sheet(item: Binding(get: { model.remoteConfirmation }, set: { if $0 == nil { model.cancelConfirmation() } })) { request in
            DaybookSheetLayout(title: "生成每日洞察", onClose: { model.cancelConfirmation() }) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("将这些文字摘录发送给所选 AI，生成洞察？").font(.system(size: 22, weight: .medium))
                    Text(request.configuration.label).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                    Text(request.configuration.mode == .chatgpt ? "OpenAI · ChatGPT" : request.configuration.baseURL)
                        .font(.system(size: 11)).textSelection(.enabled)
                    Text("仅发送下方日期、统计和允许来源的文字摘录；原始录音、图片和声音档案保留在本机。")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
                    Text(request.content).font(.system(size: 12)).lineSpacing(7).textSelection(.enabled)
                    RemoteAISendControls(buttonTitle: "确认并生成洞察") { remember in
                        model.confirm(request, rememberChoice: remember)
                    }.id(request.id)
                    Button("取消") { model.cancelConfirmation() }.buttonStyle(DaybookSettingsButtonStyle())
                }.padding(.top, 12)
            }
        }.confirmationDialog("重置本机洞察和每日次数？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("重置本机洞察存储", role: .destructive) { model.resetStorage() }
            Button("取消", role: .cancel) {}
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [DaybookStyle.blueSoft, DaybookStyle.paleBlue], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(DaybookStyle.line, lineWidth: 1)).padding(.bottom, 20)
    }
}
