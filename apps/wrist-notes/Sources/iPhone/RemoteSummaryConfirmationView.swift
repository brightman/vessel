import SwiftUI

struct RemoteSummaryConfirmationView: View {
    let request: NotesModel.RemoteSummaryRequest
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void
    var body: some View {
        DaybookSheetLayout(title: "发送确认", onClose: onCancel) {
            VStack(alignment: .leading, spacing: 18) {
                Text("将这条记录的全文发送给所选 AI？").font(.system(size: 22, weight: .medium))
                Text(request.configuration.label).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                if request.configuration.mode == .chatgpt {
                    Text("使用 ChatGPT 套餐").font(.system(size: 12))
                    Link("管理用量 ↗", destination: ChatGPTAccountModel.usageURL).font(.system(size: 12))
                } else {
                    Text(request.configuration.baseURL).font(.system(size: 11)).textSelection(.enabled)
                }
                Text("仅发送下方转写文字，原始录音、图片和声音档案保留在本机。长记录会分段总结，再合并结果。")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
                Text(request.title).font(.system(size: 14, weight: .medium))
                Text(request.text).font(.system(size: 12)).lineSpacing(7).textSelection(.enabled)
                RemoteAISendControls(buttonTitle: "确认并生成总结", onConfirm: onConfirm).id(request.id)
                Button("取消", action: onCancel).buttonStyle(DaybookSettingsButtonStyle())
            }.padding(.top, 12)
        }
    }
}

struct RemoteAISendControls: View {
    let buttonTitle: LocalizedStringKey
    var accessibilityID = "ai.send.confirm"
    let onConfirm: (Bool) -> Void
    @State private var doNotAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { doNotAskAgain.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: doNotAskAgain ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20)).foregroundStyle(DaybookStyle.accent)
                    Text("下次不再提示").font(.system(size: 14))
                }.frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(doNotAskAgain ? .isSelected : [])
            .accessibilityIdentifier("ai.send.doNotAskAgain")
            Text("适用于外部 AI 问答、总结、每日回顾、每日洞察与长录音整理。开启免提示后，每日回顾、每日洞察和录音主题、标题、总结会自动生成；录音整理会使用转写及已有时间、地点信息。可在「设置 → AI 模型」中恢复确认。")
                .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
            Button { onConfirm(doNotAskAgain) } label: { Text(buttonTitle) }
                .buttonStyle(DaybookPrimaryButtonStyle(wide: true)).accessibilityIdentifier(accessibilityID)
        }
    }
}

struct RecordingTitleAction: View {
    let note: VoiceNote
    var beforeRequest: () -> Bool = { true }
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmation: NotesModel.RemoteTitleRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard beforeRequest() else { return }
                if settings.ai.isRemote && settings.requiresRemoteAIConfirmation {
                    confirmation = model.prepareRemoteTitle(note.id)
                } else { Task { await model.generateTitle(note.id) } }
            } label: {
                HStack(spacing: 6) {
                    if model.generatingTitleIDs.contains(note.id) { ProgressView().controlSize(.mini) }
                    Image(systemName: "sparkles")
                    Text(model.generatingTitleIDs.contains(note.id) ? "正在生成标题…" : "AI 生成标题")
                }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
            .disabled(model.generatingTitleIDs.contains(note.id) || note.transcriptionState != .ready || note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error = model.titleErrors[note.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(DaybookStyle.red)
            }
        }
        .sheet(item: $confirmation) { request in
            DaybookSheetLayout(title: "生成录音标题", onClose: { confirmation = nil }) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("将这些转写摘录发送给所选 AI，生成标题？").font(.system(size: 22, weight: .medium))
                    Text(request.configuration.label).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                    Text(request.configuration.destinationDescription)
                        .font(.system(size: 11)).textSelection(.enabled)
                    Text("仅发送下方开头、中间和结尾摘录，原始音频保留在本机。生成成功后替换当前标题。")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
                    Text(request.note.displayTitle).font(.system(size: 14, weight: .medium))
                    Text(request.text).font(.system(size: 12)).lineSpacing(7).textSelection(.enabled)
                    RemoteAISendControls(buttonTitle: "确认并生成标题") { doNotAskAgain in
                        confirmation = nil
                        Task { await model.generateTitle(note.id, confirmation: request, doNotAskAgain: doNotAskAgain) }
                    }.id(request.id)
                    Button("取消") { confirmation = nil }.buttonStyle(DaybookSettingsButtonStyle())
                }.padding(.top, 12)
            }
        }
    }
}
