#!/usr/bin/env python3
"""Prepare a disposable native preview build using production views and fixture notes.
The copy uses different bundle IDs and never changes the installed production data.
"""
import json
from pathlib import Path
import shutil
import tempfile

source = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="wristnotes-ui-preview-"))
for name in ("Sources", "WristNotes.xcodeproj"):
    shutil.copytree(source / name, root / name, ignore=shutil.ignore_patterns("xcuserdata"))
project = root / "WristNotes.xcodeproj/project.pbxproj"
project.write_text(project.read_text().replace("com.vessel.wristnotes", "com.vessel.wristnotes.preview"))
info = root / "Sources/Watch/Info.plist"
info.write_text(info.read_text().replace("com.vessel.wristnotes", "com.vessel.wristnotes.preview"))
for file in ("Sources/Watch/WatchRecorder.swift", "Sources/iPhone/PhoneConnectivity.swift"):
    path = root / file
    path.write_text(path.read_text().replace("if WCSession.isSupported() {", "if false {"))
# Settings previews use only disposable drafts, never a credential or network request.
settings_view = root / "Sources/iPhone/SettingsViews.swift"
settings_view.write_text(settings_view.read_text().replace(
    'init(settings: AppSettings) { _editor = StateObject(wrappedValue: AISettingsModel(settings: settings)) }',
    '''init(settings: AppSettings) {
        let draft = AISettingsModel(settings: settings)
        if ProcessInfo.processInfo.environment["WN_PREVIEW_SCREEN"] == "ai-custom" {
            draft.configuration.mode = .custom
            draft.configuration.model = "my-model"
            draft.configuration.baseURL = "https://api.example.com/v1"
        }
        _editor = StateObject(wrappedValue: draft)
    }'''))
# Choose the initial tab in the copied view only; production starts on Summary.
detail = root / "Sources/iPhone/NoteDetailView.swift"
detail.write_text(detail.read_text().replace(
    "@State private var selectedTab: DetailTab = .summary",
    '@State private var selectedTab: DetailTab = ProcessInfo.processInfo.environment["WN_PREVIEW_SCREEN"] == "transcript" ? .transcript : .summary'))
(root / "Sources/iPhone/WristNotesApp.swift").write_text('''import SwiftUI
import AVFAudio
@main
struct WristNotesApp: App {
    @StateObject private var model: NotesModel
    static let sampleID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceNotes")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var notes = [VoiceNote]()
        let titles = ["晨间想法", "项目讨论", "路上的灵感", "会议备忘"]
        let texts = ["今天想到可以把手表录音作为随手记录的入口。录完后自动传到手机，再把语音整理成可搜索的笔记。", "讨论了第一版的范围：先完成手表长录音、录音传输、手机端转写和笔记管理。下周验证普通话长录音的识别质量。", "笔记列表应该优先展示标题、录制时间和一小段转写内容，方便快速找到录音。", ""]
        for i in 0..<4 {
            let id = i == 0 ? Self.sampleID : UUID()
            var note = VoiceNote(id: id, kind: i % 2 == 0 ? .thought : .long, capturedAt: Date().addingTimeInterval(Double(-i * 86400)), duration: [74.0, 764.0, 38.0, 315.0][i])
            note.title = titles[i]; note.transcript = texts[i]
            note.transcriptionState = i == 3 ? .unavailable : .ready
            note.summary = i == 0 ? "• 用手表快速记录想法。\\n• 录音传到手机后，整理为可搜索的语音笔记。" : ""
            note.summaryState = i == 0 ? .ready : .pending
            notes.append(note)
        }
        try! JSONEncoder().encode(notes).write(to: root.appendingPathComponent("notes.json"))
        // Silent PCM provides a real playable file; no microphone or user recording is used.
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        let destination = root.appendingPathComponent("Audio/\\(Self.sampleID.uuidString).m4a")
        let audio = try! AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
        for _ in 0..<74 { try! audio.write(from: buffer) }
        let model = NotesModel()
        model.settings.appearance = ProcessInfo.processInfo.environment["WN_PREVIEW_THEME"] == "light" ? .light : .dark
        _model = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        WindowGroup {
            Group {
                let screen = ProcessInfo.processInfo.environment["WN_PREVIEW_SCREEN"] ?? "list"
                if screen == "list" { NotesListView() }
                else {
                    NavigationStack {
                        switch screen {
                        case "settings": SettingsView {}
                        case "asr": TranscriptionSettingsView(settings: model.settings)
                        case "ai-local", "ai-custom": AISettingsView(settings: model.settings)
                        default: NoteDetailView(id: Self.sampleID)
                        }
                    }
                }
            }
            .environmentObject(model).environmentObject(model.settings)
            .preferredColorScheme(model.settings.appearance.colorScheme)
            .task {
                if ProcessInfo.processInfo.environment["WN_TEST_BASE_URL"] != nil {
                    await AIIntegrationPreview.run(model: model, noteID: Self.sampleID)
                }
            }
        }
    }
}
''')
with (root / "Sources/iPhone/WristNotesApp.swift").open("a") as app:
    app.write((source / "Tests/AIIntegrationPreview.swift").read_text())
print(json.dumps({"project": str(project.parent), "root": str(root)}))
