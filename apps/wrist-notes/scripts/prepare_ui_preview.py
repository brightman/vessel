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
for name in ("Sources", "WristNotes.xcodeproj", "Packages"):
    shutil.copytree(source / name, root / name, ignore=shutil.ignore_patterns("xcuserdata", ".build", ".swiftpm"))
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
    '@State private var selectedTab: DetailTab = ProcessInfo.processInfo.environment["WN_PREVIEW_SCREEN"] == "transcript" ? .transcript : (ProcessInfo.processInfo.environment["WN_PREVIEW_SCREEN"] == "analysis" ? .analysis : .summary)'))
# Synthetic health data is restricted to this disposable copy. Never query the user's Health store in previews.
preview_model = root / "Sources/iPhone/NotesModel.swift"
preview_model.write_text(preview_model.read_text().replace(
    'func refreshHeartRate(_ id: UUID) async {',
    'func refreshHeartRate(_ id: UUID) async {\n        if ProcessInfo.processInfo.environment["WN_PREVIEW_HEART"] == "1" { return }'))
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
        if ProcessInfo.processInfo.environment["WN_PREVIEW_HEART"] == "1" {
            let note = notes[0]
            var timeline = NoteTimeline()
            timeline.segmentTranscript = note.transcript
            let offsets: [Double] = [5, 20, 40, 65]
            let rates: [Double] = [70, 85, 75, 98]
            timeline.points = zip(offsets, rates).map { offset, bpm -> HeartRatePoint in
                let context: Int? = offset == 5 ? 1 : (offset == 20 ? 2 : nil)
                return HeartRatePoint(id: UUID(), start: note.capturedAt.addingTimeInterval(offset),
                    end: note.capturedAt.addingTimeInterval(offset + 1), bpm: bpm,
                    sourceName: "Apple Watch（模拟数据）", sourceBundle: "fixture.watch", productType: "Watch7,18", deviceName: "Fixture",
                    motionContext: context)
            }
            timeline.segments = [TranscriptSegment(start: 6, end: 18, text: "周五前确认预算。"),
                TranscriptSegment(start: 25, end: 35, text: "第一版先验证录音同步。"),
                TranscriptSegment(start: 45, end: 60, text: "下周复盘测试结果。")]
            timeline.refreshedAt = .now
            timeline.hrvPoints = [(-10.0, 18.0, 32.5), (22.0, 38.0, 41.0), (42.0, 90.0, 45.5)].map { lower, upper, value in
                HRVPoint(id: UUID(), start: note.capturedAt.addingTimeInterval(lower), end: note.capturedAt.addingTimeInterval(upper),
                    sdnnMilliseconds: value, sourceName: "Apple Watch（模拟数据）", sourceBundle: "fixture.watch", productType: "Watch7,18", deviceName: "Fixture")
            }
            timeline.hrvRefreshedAt = .now
            let day = Calendar.current.dateInterval(of: .day, for: note.capturedAt)!
            timeline.statesOfMind = [StateOfMindPoint(id: UUID(), date: note.capturedAt.addingTimeInterval(12),
                kind: .momentaryEmotion, valence: -0.3, classification: 3, labels: [29], associations: [17],
                sourceName: "Health（模拟数据）", sourceBundle: "fixture.health"),
                StateOfMindPoint(id: UUID(), date: note.capturedAt.addingTimeInterval(30),
                kind: .dailyMood, valence: 0, classification: 4, labels: [], associations: [],
                sourceName: "Health（模拟数据）", sourceBundle: "fixture.health", dayStart: day.start, dayEnd: day.end,
                timeZoneIdentifier: Calendar.current.timeZone.identifier)]
            timeline.stateOfMindRefreshedAt = .now
            if ProcessInfo.processInfo.environment["WN_PREVIEW_SPEAKERS"] == "1" {
                var speakerNote = note
                speakerNote.transcript = timeline.segments.map { $0.text }.joined()
                notes[0] = speakerNote
                try! JSONEncoder().encode(notes).write(to: root.appendingPathComponent("notes.json"))
                timeline.segmentTranscript = speakerNote.transcript
                timeline.words = timeline.segments
                timeline.diarization = SpeakerDiarization.aligned(turns: [
                    SpeakerTurn(start: 0, end: 20, speakerID: "fixture-a"),
                    SpeakerTurn(start: 20, end: 40, speakerID: "fixture-b"),
                    SpeakerTurn(start: 40, end: 74, speakerID: "fixture-a")], words: timeline.words,
                    note: speakerNote, model: "合成预览（不代表模型效果）")
                timeline.analysis = MeetingAnalysis(text: "旧的合成报告", model: "fixture", generatedAt: .now,
                    inputRevision: timeline.revision, transcript: speakerNote.transcript, summary: speakerNote.summary)
            }
            try! NoteTimelineStore(root: root).save(timeline, id: note.id)
        }
        // Silent PCM provides a real playable file; no microphone or user recording is used.
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        let destination = root.appendingPathComponent("Audio/\\(Self.sampleID.uuidString).m4a")
        let audio = try! AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
        for _ in 0..<74 { try! audio.write(from: buffer) }
        let model = ProcessInfo.processInfo.environment["WN_MEETING_TEST_BASE_URL"] == nil
            ? NotesModel() : NotesModel(settings: AppSettings(secrets: MeetingPreviewSecretStore()))
        model.settings.heartRateEnabled = ProcessInfo.processInfo.environment["WN_PREVIEW_HEART"] == "1"
        model.settings.hrvEnabled = ProcessInfo.processInfo.environment["WN_PREVIEW_HEART"] == "1"
        model.settings.stateOfMindEnabled = ProcessInfo.processInfo.environment["WN_PREVIEW_HEART"] == "1"
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
                if ProcessInfo.processInfo.environment["WN_MEETING_TEST_BASE_URL"] != nil {
                    await MeetingIntegrationPreview.run(model: model, noteID: Self.sampleID)
                }
                if ProcessInfo.processInfo.environment["WN_SPEAKER_TEST"] == "1" {
                    await SpeakerIntegrationPreview.run(model: model, noteID: Self.sampleID)
                }
            }
        }
    }
}
''')
with (root / "Sources/iPhone/WristNotesApp.swift").open("a") as app:
    app.write((source / "Tests/AIIntegrationPreview.swift").read_text())
    app.write((source / "Tests/MeetingIntegrationPreview.swift").read_text())
    app.write((source / "Tests/SpeakerIntegrationPreview.swift").read_text())
print(json.dumps({"project": str(project.parent), "root": str(root)}))
