import Foundation
import Combine

@MainActor private final class TestRecorder: AssistantVoiceRecording {
    var onEnded: (() -> Void)?
    var duration: TimeInterval = 4
    var level: Float = 0.4
    var failure: Error?
    var beforeStart: (() async -> Void)?
    var starts = 0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    func start() async throws { starts += 1; await beforeStart?(); try Task.checkCancellation(); if let failure { throw failure }; try Data([1,2,3]).write(to: url) }
    func finish() throws -> URL { if let failure { throw failure }; return url }
    func discard() { try? FileManager.default.removeItem(at: url) }
}

@MainActor private final class DelayedText {
    var continuation: CheckedContinuation<String, Never>?
    func wait() async -> String { await withCheckedContinuation { continuation = $0 } }
    func complete(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}

@main struct AssistantVoiceInputSmoke {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        precondition(condition(), "voice operation did not reach the expected state")
    }
    @MainActor static func main() async throws {
        var waveform = AssistantVoiceWaveform()
        let capacity = waveform.samples.count
        precondition(capacity > 1 && waveform.samples.allSatisfy { $0 == 0 })
        waveform.append(0.1)
        let quiet = waveform.samples.last!
        waveform.append(0.9)
        let loud = waveform.samples.last!
        precondition(loud > quiet && waveform.samples.dropLast().last == quiet,
                     "each bar must retain a recent energy sample instead of scaling a fixed shape")
        waveform.append(0)
        precondition(waveform.samples.last! > 0 && waveform.samples.last! < loud,
                     "the energy envelope should decay smoothly in silence")
        for _ in 0..<100 { waveform.append(0) }
        precondition(waveform.samples.count == capacity && waveform.samples.allSatisfy { $0 == 0 },
                     "silence must settle to baseline without growing the history")
        for level: Float in [.nan, .infinity, -.infinity, -4, 8] { waveform.append(level) }
        precondition(waveform.samples.allSatisfy { $0.isFinite && (0...1).contains($0) },
                     "invalid meter values must not produce invalid view dimensions")

        let recorder = TestRecorder()
        var configurationSeen: TranscriptionConfiguration?
        let model = AssistantVoiceInputModel(recorder: recorder, prepare: { _ in }, transcribe: { _, configuration in
            configurationSeen = configuration
            return "昨天的计划"
        })
        let config = TranscriptionConfiguration(engine: .whisper, whisperLanguage: "zh")
        model.start(configuration: config, draft: "问👋这里结尾", selection: 2..<4)
        model.start(configuration: .init(), draft: "重复启动")
        await until { model.phase == .recording }
        precondition(recorder.starts == 1 && model.result == nil, "double tapping must not start another take or send text")
        await until { model.waveform.samples.contains { $0 > 0 } }
        var wholeComposerRefreshes = 0
        let observer = model.objectWillChange.sink { wholeComposerRefreshes += 1 }
        try? await Task.sleep(for: .milliseconds(220))
        precondition(wholeComposerRefreshes == 0,
                     "meter ticks must not invalidate the entire conversation and rehash its evidence")
        observer.cancel()
        model.release(); model.release()
        precondition(model.waveform.samples.allSatisfy { $0 == 0 }, "release must stop metering and clear the waveform")
        await until { model.result != nil }
        precondition(model.result?.draft == "问👋 昨天的计划 结尾", "insert at the selected character range, including emoji")
        precondition(configurationSeen == config, "use the selected ASR configuration snapshot")
        precondition(!FileManager.default.fileExists(atPath: recorder.url.path), "completed input must discard its take")

        let blockedRecorder = TestRecorder()
        let blocked = AssistantVoiceInputModel(recorder: blockedRecorder, prepare: { _ in throw TranscriptionResourceError.missing }, transcribe: { _,_ in "wrong" })
        blocked.start(configuration: .init(), draft: "已有草稿")
        await until { blocked.phase == .recording }
        blocked.release()
        await until { blocked.errorMessage != nil }
        precondition(blocked.result == nil && !blocked.isActive && !FileManager.default.fileExists(atPath:blockedRecorder.url.path), "missing resources must preserve the draft and clean up the take")

        let resources = DelayedText(), fastRecorder = TestRecorder()
        let fast = AssistantVoiceInputModel(recorder: fastRecorder, prepare: { _ in _ = await resources.wait() }, transcribe: { _,_ in "本机转写" })
        fast.start(configuration: .init(), draft: "草稿")
        await until { fast.phase == .recording }
        precondition(resources.continuation == nil, "resource inventory must not delay microphone capture")
        fast.release()
        precondition(fast.phase == .transcribing, "release must immediately leave the listening state")
        await until { resources.continuation != nil }
        fast.cancel(); resources.complete("ready")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(fast.phase == .idle && fast.result == nil && !FileManager.default.fileExists(atPath:fastRecorder.url.path), "cancelling resource preparation must not publish a late transcript")

        let permissionRecorder = TestRecorder()
        permissionRecorder.failure = NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"Microphone denied"])
        let denied = AssistantVoiceInputModel(recorder: permissionRecorder, prepare: { _ in }, transcribe: { _,_ in "wrong" })
        denied.start(configuration: .init(), draft: "原有草稿")
        await until { denied.errorMessage != nil }
        precondition(denied.result == nil && !denied.isActive, "permission or recorder failure must retain the draft")

        let delayed = DelayedText(), lateRecorder = TestRecorder()
        let late = AssistantVoiceInputModel(recorder: lateRecorder, prepare: { _ in }, transcribe: { _,_ in await delayed.wait() })
        late.start(configuration: .init(), draft: "旧草稿")
        await until { late.phase == .recording }; late.finish()
        await until { delayed.continuation != nil }; late.cancel()
        precondition(late.result == nil && !late.isActive && !FileManager.default.fileExists(atPath:lateRecorder.url.path))
        late.start(configuration: .init(), draft: "新草稿")
        await until { late.phase == .recording }
        delayed.complete("已经取消的结果")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(late.phase == .recording && late.result == nil && FileManager.default.fileExists(atPath:lateRecorder.url.path), "stale ASR must not update or discard a new take")
        late.cancel()

        let preparation = DelayedText(), preparingRecorder = TestRecorder()
        preparingRecorder.beforeStart = { _ = await preparation.wait() }
        let preparing = AssistantVoiceInputModel(recorder: preparingRecorder, prepare: { _ in }, transcribe: { _,_ in "wrong" })
        preparing.start(configuration: .init(), draft: "草稿")
        await until { preparation.continuation != nil }; preparing.release(); preparation.complete("ready")
        try? await Task.sleep(for: .milliseconds(30))
        precondition(preparing.result == nil && !preparing.isActive && !FileManager.default.fileExists(atPath:preparingRecorder.url.path),
                     "releasing during microphone permission must not create a late take")

        let cancelledRecorder = TestRecorder()
        let cancelled = AssistantVoiceInputModel(recorder: cancelledRecorder, prepare: { _ in }, transcribe: { _,_ in "wrong" })
        cancelled.start(configuration: .init(), draft: "草稿")
        await until { cancelled.waveform.samples.contains { $0 > 0 } }
        cancelled.cancel()
        precondition(cancelled.waveform.samples.allSatisfy { $0 == 0 } && !cancelled.isActive)
        cancelledRecorder.level = 0
        cancelled.start(configuration: .init(), draft: "新草稿")
        await until { cancelled.phase == .recording }
        precondition(cancelled.waveform.samples.allSatisfy { $0 == 0 }, "new takes must not reuse a previous waveform")
        cancelled.cancel()

        let emptyRecorder = TestRecorder()
        let empty = AssistantVoiceInputModel(recorder: emptyRecorder, prepare: { _ in }, transcribe: { _,_ in " \n " })
        empty.start(configuration: .init(), draft: "已有文字")
        await until { empty.phase == .recording }; emptyRecorder.onEnded?()
        await until { empty.errorMessage != nil }
        precondition(empty.result == nil && !FileManager.default.fileExists(atPath:emptyRecorder.url.path), "empty speech must show an error and clean up")

        let interruptedRecorder = TestRecorder()
        let interrupted = AssistantVoiceInputModel(recorder: interruptedRecorder, prepare: { _ in }, transcribe: { _,_ in "wrong" })
        interrupted.start(configuration: .init(), draft: "已有文字")
        await until { interrupted.phase == .recording }
        interruptedRecorder.failure = NSError(domain:"test",code:2,userInfo:[NSLocalizedDescriptionKey:"Interrupted"])
        interruptedRecorder.onEnded?()
        precondition(interrupted.errorMessage != nil && interrupted.result == nil && !FileManager.default.fileExists(atPath:interruptedRecorder.url.path))

        let longRecorder = TestRecorder()
        let long = AssistantVoiceInputModel(recorder: longRecorder, prepare: { _ in }, transcribe: { _,_ in String(repeating:"字",count:350) })
        long.start(configuration: .init(), draft: "前文")
        await until { long.phase == .recording }; long.finish()
        await until { long.result != nil }
        precondition(long.result?.draft == "前文 " + String(repeating:"字",count:350), "retain all recognized text for editing instead of silently truncating")

        let stalledText = DelayedText(), timeoutRecorder = TestRecorder()
        let timeout = AssistantVoiceInputModel(recorder: timeoutRecorder, prepare: { _ in }, transcriptionTimeout: .milliseconds(30),
            transcribe: { _,_ in await stalledText.wait() })
        timeout.start(configuration: .init(), draft: "未发送的文字")
        await until { timeout.phase == .recording }; timeout.release()
        await until { timeout.errorMessage != nil }
        precondition(timeout.phase == .idle && timeout.result == nil && !FileManager.default.fileExists(atPath:timeoutRecorder.url.path),
                     "a stalled transcriber must stop waiting, retain the draft and clean up its audio")
        timeout.start(configuration: .init(), draft: "新草稿")
        await until { timeout.phase == .recording }; stalledText.complete("旧转写")
        try? await Task.sleep(for: .milliseconds(40))
        precondition(timeout.phase == .recording && timeout.result == nil, "an expired take must not affect the next capture")
        timeout.cancel()
        print("Assistant voice input energy waveform, hold/release, cancellation, draft insertion and cleanup checks passed")
    }
}
