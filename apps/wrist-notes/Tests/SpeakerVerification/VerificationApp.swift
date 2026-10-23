import SwiftUI

@main struct SpeakerVerificationApp: App {
    @StateObject private var model: NotesModel
    @StateObject private var settings: AppSettings
    private let id: UUID
    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SpeakerVerification")
        if CommandLine.arguments.contains("--reset-fixture") { try? FileManager.default.removeItem(at: root) }
        let repository = try! NoteRepository(root: root)
        let id = UUID(uuidString: "7CA53296-7777-4444-9999-020202020202")!
        if repository.notes.isEmpty {
            let audio = root.appendingPathComponent("fixture.m4a")
            try! Data([0]).write(to: audio)
            _ = try! repository.importRecording(id: id, from: audio, kind: .long, capturedAt: .now, duration: 15)
            try! repository.update(id: id) {
                $0.title = "设计讨论 · 示例"
                $0.summary = "周五确认设计方案，下周开始测试。"
                $0.applyTranscription(.init(text: "我们周五确认设计方案。 好的，下周开始测试。", segments: [
                    .init(start: 0, end: 5, text: "我们周五确认设计方案。", speakerID: "speaker-1"),
                    .init(start: 5.5, end: 10, text: " 好的，下周开始测试。", speakerID: "speaker-2")]))
                $0.transcriptionState = .ready; $0.diarizationState = .ready
            }
        }
        let settings = AppSettings()
        self.id = id
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: NotesModel(repository: repository, settings: settings, connectWatch: false))
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Text("说话人功能验证 · 示例数据")
                    NavigationLink("日记详情") { DaybookVoiceDetailView(id: id, playbackAllowed: false) }
                    NavigationLink("编辑详情") { NoteDetailView(id: id) }
                    NavigationLink("转写设置") { TranscriptionSettingsView(settings: settings) }
                }.navigationTitle("Speaker Check")
            }.environmentObject(model).environmentObject(settings)
        }
    }
}
