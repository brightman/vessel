import SwiftUI

struct DaybookRecapCard: View {
    let entry: DaybookRecapEntry
    var yesterday = false
    let stale: Bool
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    DaybookIcon("BookOpen", size: 15)
                    Text(DaybookHomeRecapTitle.text(date: entry.scope.start, yesterday: yesterday, localeIdentifier: DaybookFormat.language.rawValue))
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text(stale ? "有新记录 · 待更新" : "每日记录").font(.system(size: 9)).foregroundStyle(DaybookStyle.recapMuted)
                }.foregroundStyle(DaybookStyle.recapLabel).padding(.bottom, 11)
                Text(entry.text ?? "记录正在整理，回顾生成后会出现在这里。")
                    .font(.system(size: 13)).lineSpacing(7).multilineTextAlignment(.leading).lineLimit(4).padding(.bottom, 14)
                HStack {
                    Text(stale ? "有新记录 · 可手动更新" : "来自 \(entry.references.filter { $0.number != nil }.count) 条记录")
                        .foregroundStyle(DaybookStyle.recapLabel)
                    Spacer()
                    Text("查看回顾"); DaybookIcon("ArrowUpRight", size: 12)
                }.font(.system(size: 10)).foregroundStyle(DaybookStyle.accent).padding(.top, 12)
                    .overlay(alignment: .top) { DaybookStyle.recapBorder.frame(height: 1) }
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DaybookStyle.recapSurface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(DaybookStyle.recapBorder, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("recap.card.\(entry.dayKey)")
    }
}

struct DaybookRecapHome: View {
    @ObservedObject var model: DaybookRecapModel
    let date: Date
    let yesterday: Bool
    let onOpen: () -> Void
    var body: some View {
        Group {
            if let entry = model.entries.first(where: { $0.dayKey == DaybookRecapInput.key(date) }), entry.text != nil {
                DaybookRecapCard(entry: entry, yesterday: yesterday, stale: model.isStale(entry), onOpen: onOpen)
            } else {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: 10) {
                        if model.isLoading || model.isGenerating { ProgressView().controlSize(.small) }
                        else { DaybookIcon("BookOpen", size: 17) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(DaybookHomeRecapTitle.text(date: date, yesterday: yesterday, localeIdentifier: DaybookFormat.language.rawValue))
                                .font(.system(size: 10, weight: .semibold))
                            Text(LocalizedStringKey(status)).font(.system(size: 11)).lineSpacing(5)
                        }
                        Spacer(); DaybookIcon("ChevronRight", size: 13)
                    }.foregroundStyle(DaybookStyle.secondary).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("recap.home")
            }
        }.padding(.bottom, 20)
    }
    private var status: String {
        if model.storageError != nil { return "回顾暂时无法读取，点开重试。" }
        if model.isGenerating { return "正在生成回顾…" }
        if model.isLoading { return "正在整理当天的记录…" }
        if model.input?.references.isEmpty != false { return yesterday ? "昨天还没有可回顾的记录。" : "这一天还没有可回顾的记录。" }
        if model.input?.sources.isEmpty != false { return "文字尚未就绪，转写完成后可生成回顾。" }
        return "回顾尚未生成，点开手动生成。"
    }
}

struct DaybookRecapDetailView: View {
    @ObservedObject var model: DaybookRecapModel
    @EnvironmentObject private var settings: AppSettings
    let date: Date
    let onOpen: (UUID) -> Void
    let onClose: () -> Void
    @State private var confirmation: DaybookRecapModel.RemoteRequest?

    var body: some View {
        DaybookSheetLayout(title: "\(DaybookFormat.day(date)) · 回顾", onClose: onClose) {
            VStack(alignment: .leading, spacing: 19) {
                Label("每日回顾", systemImage: "book.closed").font(.system(size: 12)).foregroundStyle(DaybookStyle.accent)
                if let error = model.storageError {
                    Text(error).font(.system(size: 13)).foregroundStyle(DaybookStyle.red)
                    Button("重试读取回顾") { model.reload() }.buttonStyle(DaybookSettingsButtonStyle())
                } else if model.isLoading {
                    ProgressView("正在整理当天的记录…")
                } else {
                    if let entry = model.current, let text = entry.text {
                        if model.isStale {
                            DaybookQuietInfo(text: "有新记录 · 待更新。以下为较早版本，尚未包含新加入的记录。")
                        }
                        Text(text).font(.system(size: 16)).lineSpacing(9).textSelection(.enabled)
                        Text(entry.coverage).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
                        if let generatedAt = entry.generatedAt {
                            Text("\(entry.provider) · \(generatedAt.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        sources(entry)
                    } else {
                        DaybookQuietInfo(text: model.input?.references.isEmpty != false ? "这一天还没有可回顾的记录。" : model.input?.sources.isEmpty != false ? "文字还未就绪。转写完成后，可以生成回顾。" : "回顾尚未生成，可点击下方按钮手动生成。")
                    }
                    Text("结合生活、工作与学习记录回顾这一天，按需给出跟进建议。推断可能有误，请核对来源；建议不会自动创建待办或日程。")
                        .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
                    if model.isGenerating {
                        ProgressView("正在生成回顾…")
                        Button("取消生成") { model.cancel() }.font(.system(size: 12))
                    } else {
                        if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary) }
                        if settings.ai.isRemote && settings.requiresRemoteAIConfirmation && model.input?.sources.isEmpty == false {
                            Text("使用所选外部 AI，需要你确认将发送的文字。原始文件保留在本机。")
                                .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
                        }
                        Button(model.current?.text == nil ? "生成每日回顾" : "更新每日回顾") {
                            if settings.ai.isRemote && settings.requiresRemoteAIConfirmation { confirmation = model.remoteRequest() }
                            else { model.generate() }
                        }.buttonStyle(DaybookPrimaryButtonStyle(wide: true)).disabled(!model.canGenerate)
                            .accessibilityIdentifier("recap.generate")
                    }
                }
            }.padding(.top, 12)
        }.sheet(item: $confirmation) { request in
            DaybookSheetLayout(title: "回顾 · 发送确认", onClose: { confirmation = nil }) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("将这些记录摘录发送给所选 AI，生成每日回顾？").font(.system(size: 21, weight: .medium))
                    Text(request.configuration.label).font(.system(size: 12))
                    Text(request.configuration.destinationDescription)
                        .font(.system(size: 11)).textSelection(.enabled)
                    Text("只发送下方文字。长文本使用开头、中间和结尾摘录，多条记录会分批归纳后合并。原始音频和图片保留在本机。")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).lineSpacing(5)
                    Text(request.input.preview).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled)
                    RemoteAISendControls(buttonTitle: "确认并生成回顾") { remember in
                        confirmation = nil; model.generate(confirmation: request, rememberChoice: remember)
                    }.id(request.id)
                }.padding(.top, 12)
            }
        }
    }
    private func sources(_ entry: DaybookRecapEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来自当天 \(entry.references.filter { $0.number != nil }.count) 条记录").font(.system(size: 12, weight: .medium))
            ForEach(entry.references.filter { $0.number != nil }) { source in
                Button { onOpen(source.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("[\(source.number!)] \(source.title)").font(.system(size: 13))
                            Text(source.capturedAt.formatted(.dateTime.hour().minute())).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        Spacer(); DaybookIcon("ChevronRight", size: 13)
                    }.padding(.vertical, 7)
                }.buttonStyle(.plain).disabled(model.record(source.id) == nil)
            }
        }.padding(.top, 8)
    }
}
