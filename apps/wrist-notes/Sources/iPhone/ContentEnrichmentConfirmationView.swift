import SwiftUI

/// Preview uses the same immutable source scope as the authorization. Pages avoid
/// constructing a multi-hour transcript in one SwiftUI Text or on the main actor.
struct ContentEnrichmentConfirmationView: View {
    let request: ContentEnrichmentConfirmation
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void
    @EnvironmentObject private var processing: AudioProcessingModel
    @State private var transcriptPage = 0
    @State private var locationPage = 0
    @State private var spans: [AudioTranscriptSpan] = []
    @State private var context = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.scope.segmentID == nil ? "将这份录音的转写和地点信息发送给所选 AI？" : "仅将所选片段的转写和相关时间、地点信息发送给所选 AI？").font(.headline)
                    Text(request.configuration.label)
                    Text(request.configuration.mode == .chatgpt ? "OpenAI · ChatGPT" : request.configuration.baseURL).font(.caption).textSelection(.enabled)
                    Text(request.scope.segmentID == nil ? "AI 会分批阅读下方转写、采样地点和时间，并使用中间摘要整理主题、标题与总结。原始音频保留在本机。" : request.scope.field == .title ? "本次只生成所选片段标题；AI 会读取下方片段全文及时间、地点上下文。原始音频保留在本机。" : "本次只生成所选片段摘要；AI 会读取下方片段全文及时间、地点上下文。原始音频保留在本机。").font(.subheadline)
                    Text("本次确认仅适用于当前这份数据和所选模型；新增转写、地点或更换模型后会重新确认。").font(.caption).foregroundStyle(.secondary)
                }
                Section("时间与地点") {
                    Text(context).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("上一页地点") { locationPage -= 1 }.disabled(locationPage == 0 || loading)
                        Spacer()
                        Button("下一页地点") { locationPage += 1 }.disabled(context.split(separator:"\n").count < ContentEnrichmentAuthorization.pageSize || loading)
                    }
                }
                Section("转写全文 · 第 \(transcriptPage+1) 页") {
                    if let first=spans.first, let last=spans.last {
                        Text("\(RecordingFormat.timecode(first.start))–\(RecordingFormat.timecode(last.end))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(spans.map(\.text).joined(separator:" ")).font(.subheadline).textSelection(.enabled)
                    HStack {
                        Button("上一页全文") { transcriptPage -= 1 }.disabled(transcriptPage == 0 || loading)
                        Spacer()
                        Button("下一页全文") { transcriptPage += 1 }.disabled(spans.count < ContentEnrichmentAuthorization.pageSize || loading)
                    }
                }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.orange) }
                Section {
                    RemoteAISendControls(buttonTitle:request.scope.segmentID == nil ? "确认并整理录音" : request.scope.field == .title ? "确认并生成标题" : "确认并生成摘要",onConfirm:onConfirm).disabled(loading || error != nil)
                    Button("取消",role:.cancel,action:onCancel)
                }
            }
            .navigationTitle(request.scope.segmentID == nil ? "整理录音 · 发送确认" : "生成片段内容 · 发送确认")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消",action:onCancel) } }
            .task(id:"\(transcriptPage):\(locationPage)") { await load() }
        }
    }
    private func load() async {
        loading=true; error=nil
        let scope=request.scope, textOffset=transcriptPage*ContentEnrichmentAuthorization.pageSize, locationOffset=locationPage*ContentEnrichmentAuthorization.pageSize
        do {
            let value=try await processing.withRepository { repository in
                let db=repository.derivedDatabase
                return (try ContentEnrichmentAuthorization.transcriptPage(database:db,scope:scope,offset:textOffset),
                        try ContentEnrichmentAuthorization.contextPage(database:db,scope:scope,offset:locationOffset))
            }
            guard !Task.isCancelled else { return }
            spans=value.0; context=value.1
        } catch {
            guard !Task.isCancelled else { return }
            self.error="录音数据已更新，请关闭后重新打开确认。"
        }
        loading=false
    }
}
