import AppIntents
import AVFAudio
import LocalAuthentication
import UIKit

struct ToggleWiseLifeRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "开始／停止录音"
    static var description = IntentDescription("开始 WiseLife 录音；已在录音时，停止并自动保存到本机。适合绑定操作按钮。")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await WiseLifeRuntime.shared.prepare()
        if WiseLifeRuntime.shared.recording.phase == .idle {
            try await prepareWiseLifeRecordingMicrophone(for: self)
        }
        let result = try await WiseLifeRuntime.shared.perform(.toggle)
        return .result(dialog: recordingDialog(result))
    }
}

struct SaveWiseLifeRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "停止并保存录音"
    static var description = IntentDescription("停止当前的 WiseLife 录音，并自动保存到本机。")
    static var supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await WiseLifeRuntime.shared.perform(.stop)
        return .result(dialog: recordingDialog(result))
    }
}

/// Answers only from this device's persisted voice notes and still-current daily recaps.
/// It deliberately ignores the user's remote AI configuration and never writes a chat turn.
struct AskWiseLifeRecordsIntent: AppIntent {
    static var title: LocalizedStringResource = "询问 WiseLife 记录"
    static var description = IntentDescription("从本机语音记录和每日回顾中查找内容，并使用设备端模型回答。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "问题", description: "例如：昨天我记录了哪些预算想法？")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .result(dialog: "请告诉 Siri 你想查什么 WiseLife 记录。") }
        guard question.count <= 300 else { return .result(dialog: "问题请缩短到 300 字以内。") }

        let settings = AppSettings()
        if settings.requiresFaceID {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "解锁 WiseLife 本地记录查询") else {
                    return .result(dialog: "身份验证未完成，WiseLife 没有读取记录。")
                }
            } catch {
                return .result(dialog: "请先通过身份验证，再询问 WiseLife 的私人记录。")
            }
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            return .result(dialog: "请先解锁 iPhone，再查询 WiseLife 本地记录。")
        }
        let allowedKinds = DaybookPreferences().allowedKinds.intersection([.voice, .thought])
        guard !allowedKinds.isEmpty else {
            return .result(dialog: "你已在 WiseLife 设置中禁止 AI 使用语音记录，因此 Siri 查询不会读取这些内容。")
        }

        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let voiceNotesRoot = documents.appendingPathComponent("VoiceNotes", isDirectory: true)
            let notes = try NoteRepository(root: voiceNotesRoot).notes
            var records = notes.map(DaybookPlaces.voice)
            records.append(contentsOf: try currentRecapRecords(from: DaybookRecapStore().load(), currentRecords: records))

            let prepared = try WiseLifeSiriQuery.prepare(question: question, records: records, allowedKinds: allowedKinds)
            guard !prepared.sources.isEmpty else {
                return .result(dialog: "我没有在本机已转写的语音记录或每日回顾中找到相关内容。")
            }
            let answer: String
            if let direct = prepared.directResponse {
                answer = direct
            } else {
                // Force the on-device model even when the app's interactive assistant is configured remotely.
                do {
                    answer = try await DaybookAnswerService().answer(prepared, configuration: AIConfiguration(), apiKey: nil)
                } catch DaybookAnswerFailure.unavailable {
                    return .result(dialog: "Apple 本机模型暂不可用。请稍后重试，或打开 WiseLife 查看已找到的记录。")
                } catch DaybookAnswerFailure.unsupportedLanguage {
                    return .result(dialog: "Apple 本机模型当前不能用中文回答。请打开 WiseLife 查看已找到的记录。")
                } catch {
                    return .result(dialog: "本机模型暂时无法生成有来源依据的回答。请打开 WiseLife 查看已找到的记录。")
                }
            }
            let references = prepared.sources.map {
                "来源 \($0.number)：\($0.title)，\($0.capturedAt.formatted(date: .abbreviated, time: .shortened))"
            }.joined(separator: "；")
            let dialog = references.isEmpty ? answer : "\(answer) 相关记录：\(references)"
            return .result(dialog: IntentDialog(stringLiteral: dialog))
        } catch {
            return .result(dialog: "WiseLife 暂时无法安全读取或回答本机记录。请解锁 WiseLife 后重试。")
        }
    }

    private func currentRecapRecords(from entries: [DaybookRecapEntry], currentRecords: [DayRecord]) -> [DayRecord] {
        let recordsByID = Dictionary(currentRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return entries.compactMap { entry in
            guard let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !entry.references.isEmpty,
                  entry.references.allSatisfy({ reference in
                      guard let current = recordsByID[reference.id] else { return false }
                      let digest = DaybookRecapInput.factDigest(current)
                      return digest == reference.digest || digest == reference.legacyDigest
                  }) else { return nil }
            return DayRecord(id: UUID(), capturedAt: entry.scope.start, kind: .thought,
                             title: "每日回顾", text: "已保存的每日回顾：\(text)")
        }
    }
}

struct WiseLifeRecordingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)记此刻", "Toggle recording in \(.applicationName)"
        ], shortTitle: "开始／停止录音", systemImageName: "record.circle")
        AppShortcut(intent: StartWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)开始录音", "Start recording in \(.applicationName)"
        ], shortTitle: "开始录音", systemImageName: "mic.fill")
        AppShortcut(intent: SaveWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)停止录音", "Stop recording in \(.applicationName)"
        ], shortTitle: "停止并保存录音", systemImageName: "stop.circle")
        AppShortcut(intent: AskWiseLifeRecordsIntent(), phrases: [
            "询问\(.applicationName)中的记录", "Ask about my records in \(.applicationName)"
        ], shortTitle: "询问记录", systemImageName: "magnifyingglass")
    }
}

@MainActor
func prepareWiseLifeRecordingMicrophone<I: AppIntent>(for intent: I) async throws {
    if !UIApplication.shared.isProtectedDataAvailable || AVAudioApplication.shared.recordPermission == .undetermined {
        if UIApplication.shared.applicationState != .active {
            try await intent.continueInForeground("请打开 WiseLife，完成首次麦克风授权后开始录音。")
        }
    }
    guard AVAudioApplication.shared.recordPermission != .denied else {
        throw NSError(domain: "WiseLife.Recording.Permission", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "请在系统设置中允许 WiseLife 使用麦克风，然后重试。"])
    }
    if AVAudioApplication.shared.recordPermission == .undetermined {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "WiseLife.Recording.Permission", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未获得麦克风权限，未开始录音。"])
        }
    }
    try Task.checkCancellation()
}

func recordingDialog(_ outcome: WiseLifeRuntime.Outcome) -> IntentDialog {
    switch outcome {
    case .recording: "正在录音"
    case .saved: "录音已保存"
    case .unchanged: "当前没有进行中的录音"
    }
}
