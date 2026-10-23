import SwiftUI

struct DesktopLibraryView: View {
    @ObservedObject var model: DesktopModel
    @State private var filter = 0
    @State private var search = ""
    private var filtered: [DesktopLibraryItem] {
        model.items.filter { item in
            (filter != 1 || item.summary != nil) && (filter != 2 || item.summary == nil) &&
            (search.isEmpty || item.transcript.title.localizedCaseInsensitiveContains(search) || item.transcript.text.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 206)
            DesktopStyle.line.frame(width: 1)
            library.frame(width: 312)
            DesktopStyle.line.frame(width: 1)
            if let item = model.items.first(where: { $0.id == model.selectedID }) { DesktopRecordingDetail(model: model, item: item).id(item.id) }
            else { emptyDetail.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .foregroundStyle(DesktopStyle.ink).background(DesktopStyle.paper).tint(DesktopStyle.accent)
        .frame(minWidth: 1060, minHeight: 720)
        .sheet(isPresented: $model.showPairing) { DesktopPairingView(model: model) }
        .sheet(isPresented: $model.showModelSettings) { DesktopModelSettingsView(model: model) }
        .confirmationDialog("使用自定义模型生成总结？", isPresented: Binding(get: { model.pendingRemoteItem != nil }, set: { if !$0 { model.pendingRemoteItem = nil } }), titleVisibility: .visible) {
            Button("发送转写文字并生成") { if let item = model.pendingRemoteItem { model.pendingRemoteItem = nil; model.generate(item, allowExternal: true) } }
        } message: { Text("将这条录音的转写文字发送至 \(model.configuration.providerHost)，使用 \(model.configuration.model) 整理。音频保留在手机。") }
        .alert("WiseLife", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.pages").font(.system(size: 25, weight: .light)).foregroundStyle(DesktopStyle.accent)
                VStack(alignment: .leading, spacing: 3) { Text("WiseLife").font(.system(size: 21, weight: .semibold)); Text("留住值得回看的时刻").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary) }
            }.padding(.bottom, 38)
            Text("我的记录").font(.system(size: 10, weight: .medium)).foregroundStyle(DesktopStyle.secondary).padding(.horizontal, 12).padding(.bottom, 12)
            nav("全部录音", icon: "waveform", index: 0, count: model.items.count)
            nav("已有总结", icon: "text.alignleft", index: 1, count: model.items.filter { $0.summary != nil }.count)
            nav("待整理", icon: "tray", index: 2, count: model.items.filter { $0.summary == nil }.count)
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: "lock.shield").font(.system(size: 20, weight: .light)).foregroundStyle(DesktopStyle.accent)
                Text("从本机开始").font(.system(size: 12, weight: .medium))
                Text("文字在你的设备间流转，\n按你的选择整理与回看。")
                    .font(.system(size: 10)).lineSpacing(5).foregroundStyle(DesktopStyle.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DesktopStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16)).padding(.bottom, 20)
            Button { model.showPairing = true } label: { Label("同步与配对", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, alignment: .leading) }.padding(.vertical, 10)
            Button { model.showModelSettings = true } label: { Label("AI 模型", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.padding(.vertical, 10)
            HStack(spacing: 6) { Circle().fill(model.port > 0 ? DesktopStyle.green : DesktopStyle.secondary).frame(width: 5, height: 5); Text(model.serverStatus).lineLimit(2) }
                .font(.system(size: 9)).foregroundStyle(DesktopStyle.secondary).padding(.top, 18)
        }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 24)
    }
    private func nav(_ title: String, icon: String, index: Int, count: Int) -> some View {
        Button { filter = index } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 17); Text(title); Spacer(); Text("\(count)").font(.system(size: 10)).monospacedDigit() }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(filter == index ? DesktopStyle.accent : DesktopStyle.secondary)
                .background(filter == index ? DesktopStyle.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.padding(.bottom, 5).accessibilityAddTraits(filter == index ? .isSelected : [])
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text(["全部录音", "已有总结", "待整理"][filter]).font(.system(size: 24, weight: .semibold)); Text("让思绪，慢慢清晰。").font(.system(size: 11)).foregroundStyle(DesktopStyle.secondary) }; Spacer() }
                .padding(.horizontal, 24).padding(.top, 53).padding(.bottom, 24)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(DesktopStyle.secondary); TextField("搜索标题与转写", text: $search).textFieldStyle(.plain) }
                .font(.system(size: 12)).padding(11).background(DesktopStyle.field, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 20).padding(.bottom, 20)
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: search.isEmpty ? "iphone.and.arrow.right" : "magnifyingglass").font(.system(size: 28, weight: .ultraLight))
                    Text(search.isEmpty ? "等待第一条记录" : "没有找到相关记录").font(.system(size: 14, weight: .medium))
                    Text(search.isEmpty ? "将 iPhone 与 Mac 配对，\n已完成的转写会出现在这里。" : "试试其他关键词。")
                        .font(.system(size: 11)).lineSpacing(5).foregroundStyle(DesktopStyle.secondary)
                    if search.isEmpty { Button("连接 iPhone") { model.showPairing = true }.buttonStyle(DesktopQuietButton()) }
                }.padding(24)
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(filtered) { item in
                        Button { model.selectedID = item.id } label: { row(item) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }
            HStack { Image(systemName: "text.bubble"); Text("仅同步文字，音频保留在手机") }.font(.system(size: 9)).foregroundStyle(DesktopStyle.secondary).padding(20)
        }
    }
    private func row(_ item: DesktopLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Text(item.transcript.capturedAt.formatted(.dateTime.month().day().hour().minute())).font(.system(size: 10)); Spacer(); Image(systemName: item.transcript.captureDevice.contains("Watch") ? "applewatch" : "iphone") }.foregroundStyle(DesktopStyle.secondary)
            Text(item.transcript.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text(item.transcript.text.isEmpty ? "等待手机转写完成…" : item.transcript.text).font(.system(size: 11)).lineSpacing(5).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(DesktopStyle.secondary)
            HStack(spacing: 6) {
                Image(systemName: item.summary != nil ? "checkmark.circle" : "circle.dotted")
                Text(item.summary != nil ? "已整理" : (item.transcript.isFinal ? "待整理" : "转写更新中"))
                Spacer(); Text(DesktopStyle.timestamp(item.transcript.duration)).monospacedDigit()
            }.font(.system(size: 9)).foregroundStyle(item.summary != nil ? DesktopStyle.green : DesktopStyle.secondary)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedID == item.id ? DesktopStyle.blueSoft : DesktopStyle.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(model.selectedID == item.id ? DesktopStyle.accent.opacity(0.22) : DesktopStyle.line, lineWidth: 1))
    }
    private var emptyDetail: some View {
        VStack(spacing: 18) {
            Image(systemName: "text.book.closed").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(DesktopStyle.accent.opacity(0.7))
            Text("把记录，整理成值得回看的内容").font(.system(size: 21, weight: .medium))
            Text("选择一条录音，查看转写、说话人与模型总结。").font(.system(size: 12)).foregroundStyle(DesktopStyle.secondary)
            Button("同步与配对") { model.showPairing = true }.buttonStyle(DesktopPrimaryButton()).padding(.top, 4)
        }.padding(30)
    }
}

private struct DesktopRecordingDetail: View {
    @ObservedObject var model: DesktopModel
    let item: DesktopLibraryItem
    @State private var tab = 0
    @State private var selectedSpan: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Label("语音记录", systemImage: "waveform"); Spacer(); Label(item.deviceName, systemImage: "iphone") }.font(.system(size: 11)).foregroundStyle(DesktopStyle.secondary).padding(.horizontal, 32).padding(.top, 56).padding(.bottom, 28)
            VStack(alignment: .leading, spacing: 13) {
                Text(item.transcript.title).font(.system(size: 30, weight: .semibold)).lineSpacing(5).textSelection(.enabled)
                HStack(spacing: 14) {
                    Label(item.transcript.capturedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Label(DesktopStyle.timestamp(item.transcript.duration), systemImage: "clock")
                    Text(item.transcript.captureDevice)
                }.font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                HStack(spacing: 4) {
                    ForEach(["内容概览", "转写全文"].indices, id: \.self) { index in
                        Button { tab = index } label: {
                            Text(["内容概览", "转写全文"][index]).font(.system(size: 12, weight: tab == index ? .medium : .regular))
                                .padding(.horizontal, 17).padding(.vertical, 9).background(tab == index ? DesktopStyle.card : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }.padding(4).background(DesktopStyle.field, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 16)
            }.padding(.horizontal, 32).padding(.bottom, 22)
            DesktopStyle.line.frame(height: 1).padding(.horizontal, 32)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if tab == 0 { summary }
                        else { transcript }
                    }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: selectedSpan) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                    .onChange(of: tab) { _, value in if value == 1, let selectedSpan { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(selectedSpan, anchor: .center) } } } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(model.configuration.isLocal ? "在这台 Mac 上整理" : "使用自定义模型整理", systemImage: "sparkles").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.generatingID == item.id { Button("取消") { model.cancelGeneration() }.buttonStyle(DesktopQuietButton()) }
                else { Button(item.summary == nil ? "生成总结" : "重新生成") { model.generate(item) }.buttonStyle(DesktopPrimaryButton()).disabled(!item.transcript.isFinal || item.transcript.text.isEmpty || model.generatingID != nil) }
            }
            if model.generatingID == item.id {
                HStack(spacing: 12) { ProgressView().controlSize(.small); VStack(alignment: .leading, spacing: 5) { Text(model.generationProgress).font(.system(size: 13, weight: .medium)); Text("可取消，已完成的分段会保留。下次生成可继续。").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary) } }.desktopCard()
            }
            if let summary = item.summary {
                DesktopSummaryText(text: summary.markdown).desktopCard()
                HStack(spacing: 6) { Image(systemName: "cpu"); Text("\(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))") }.font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                if let location = summary.processingLocation { Text(location + (summary.providerHost.map { " · " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary) }
                Text("AI 生成，请结合原文确认。手机下次同步时会接收此总结。").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                VStack(alignment: .leading, spacing: 13) {
                    Text("回到原文").font(.system(size: 13, weight: .semibold))
                    ForEach(summary.references) { reference in
                        Button { select(reference) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("[\(reference.id)]").font(.system(size: 10, weight: .medium)).foregroundStyle(DesktopStyle.accent).frame(width: 38, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(reference.start.map(DesktopStyle.timestamp) ?? "原文摘录").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                                    Text(reference.text).font(.system(size: 12)).lineSpacing(5).lineLimit(3).multilineTextAlignment(.leading)
                                }; Spacer(minLength: 0); Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
                            }.padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }.desktopCard()
            } else if model.generatingID != item.id {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "text.alignleft").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(DesktopStyle.accent)
                    Text(item.transcript.isFinal ? "给这段记录，一份清晰的概览" : "转写还在更新中").font(.system(size: 17, weight: .medium))
                    Text(item.transcript.isFinal ? "从全文提取讨论要点、明确决定和行动项。每一条结论都能回到原文核对。" : "等待手机完成转写并同步后，再使用 Mac 本机模型整理。")
                        .font(.system(size: 12)).lineSpacing(7).foregroundStyle(DesktopStyle.secondary)
                    if model.configuration.model.isEmpty { Button("配置 AI 模型") { model.showModelSettings = true }.buttonStyle(DesktopQuietButton()) }
                }.desktopCard()
            }
        }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("手机转写原文").font(.system(size: 13, weight: .medium)); Spacer(); Text("在手机编辑后同步更新").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary) }
            if item.transcript.spans.isEmpty { Text(item.transcript.text.isEmpty ? "尚无转写文字。" : item.transcript.text).font(.system(size: 14)).lineSpacing(9).textSelection(.enabled).desktopCard() }
            if !item.transcript.spans.isEmpty && item.transcript.spans.map(\.text).joined().filter({ !$0.isWhitespace }) != item.transcript.text.filter({ !$0.isWhitespace }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("完整原文 · 部分文字没有时间戳").font(.system(size: 11)).foregroundStyle(DesktopStyle.secondary)
                    Text(item.transcript.text).font(.system(size: 14)).lineSpacing(9).textSelection(.enabled)
                }.desktopCard()
            }
            ForEach(item.transcript.spans) { span in
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        Text(span.start.map(DesktopStyle.timestamp) ?? "原文").monospacedDigit().foregroundStyle(DesktopStyle.accent)
                        if let speaker = span.speaker { Text(speaker).foregroundStyle(DesktopStyle.secondary) }
                    }.font(.system(size: 10, weight: .medium))
                    Text(span.text).font(.system(size: 14)).lineSpacing(9).textSelection(.enabled)
                }.desktopCard().id(span.id)
            }
            Text("音频保留在手机，时间戳用于定位文字。").font(.system(size: 10)).foregroundStyle(DesktopStyle.secondary)
        }
    }
    private func select(_ reference: DesktopTranscriptSpan) {
        let match = item.transcript.spans.first { reference.start != nil ? $0.start == reference.start : $0.text.contains(reference.text) }
        selectedSpan = match?.id; tab = 1
    }
}

/// Render model text without activating model-supplied links or HTML.
struct DesktopSummaryText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") { Text(line.drop(while: { $0 == "#" || $0 == " " })).font(.system(size: 15, weight: .semibold)).padding(.top, 12) }
                else if !line.isEmpty { Text(line).font(.system(size: 13)).lineSpacing(7).foregroundStyle(DesktopStyle.bodyText) }
            }
        }.textSelection(.enabled)
    }
}
