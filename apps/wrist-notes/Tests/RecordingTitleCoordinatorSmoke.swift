import Foundation

private final class TitleSecrets: SecretStore {
    var value = "fixture-only"
    func read() throws -> String { value }
    func write(_ value: String) throws { self.value = value }
}

@main
struct RecordingTitleCoordinatorSmoke {
    @MainActor static func main() async throws {
        let suite = "RecordingTitleCoordinator-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: TitleSecrets())
        try settings.saveAI(AIConfiguration(mode: .custom, model: "fixture", baseURL: "https://example.invalid/v1"), apiKey: "fixture-only")
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 3661)
        note.applyTranscription(.init(text: "讨论产品首版范围和发布安排。")); note.transcriptionState = .ready
        var calls = 0
        var output: String? = "产品首版发布安排"
        var delayed = false
        var pending: CheckedContinuation<String?, Error>?
        var lastCurrent: (@MainActor () -> Bool)?
        func settle() async { for _ in 0..<300 { await Task.yield() } }
        func wait(line: UInt = #line, _ condition: () -> Bool) async {
            for _ in 0..<3000 { if condition() { return }; await Task.yield() }
            preconditionFailure("Title generation state not reached at line \(line), calls=\(calls)")
        }
        let coordinator = RecordingTitleCoordinator(settings: settings, notes: { [note] }, save: { snapshot, title, source, manual in
            note.applyGeneratedRecordingTitle(title, source: source, expectedRevision: snapshot.transcriptRevision,
                expectedTitle: snapshot.title, replacingExisting: manual)
        }, generate: { _, configuration, isCurrent in
            precondition(configuration.mode == .custom && isCurrent())
            calls += 1
            lastCurrent = isCurrent
            if delayed { return try await withCheckedThrowingContinuation { pending = $0 } }
            return output
        })
        coordinator.refresh()
        for _ in 0..<50 { await Task.yield() }
        precondition(calls == 0, "Remote title generation must wait for remembered consent")
        settings.requiresRemoteAIConfirmation = false
        for _ in 0..<1000 where note.titleSource != .model { await Task.yield() }
        precondition(note.displayTitle == "长录音·产品首版发布安排" && calls == 1, "Authorized automatic generation must use the selected model and save its title")
        coordinator.refresh()
        for _ in 0..<50 { await Task.yield() }
        precondition(calls == 1, "Refreshing must not regenerate a completed model title")
        note.applyEdit(title: "我手写的标题", transcript: note.transcript)
        coordinator.refresh(); await settle()
        precondition(calls == 1 && note.title == "我手写的标题", "Automatic work must preserve a manually edited title")
        await coordinator.generate(note.id)
        precondition(calls == 2 && note.titleSource == .model, "An explicit generate action may replace the current title")

        settings.requiresRemoteAIConfirmation = true
        note.applyTranscription(.init(text: "更新后的产品范围")); note.transcriptionState = .ready
        let stale = coordinator.request(for: note.id)!
        note.applyEdit(title: note.title, transcript: "再次修改产品范围")
        await coordinator.generate(note.id, confirmation: stale, doNotAskAgain: true)
        precondition(calls == 2 && settings.requiresRemoteAIConfirmation, "Stale title confirmation must not send or remember consent")
        let explicit = coordinator.request(for: note.id)!
        await coordinator.generate(note.id, confirmation: explicit)
        precondition(calls == 3 && settings.requiresRemoteAIConfirmation, "One-time confirmation permits just this title without changing preference")
        note.applyTranscription(.init(text: "第三版产品安排")); note.transcriptionState = .ready
        await coordinator.generate(note.id, confirmation: coordinator.request(for: note.id), doNotAskAgain: true)
        precondition(calls == 4 && !settings.requiresRemoteAIConfirmation, "Title confirmation can save the shared opt-out")

        output = nil
        note.applyTranscription(.init(text: "临时摘句内容。后续讨论")); note.transcriptionState = .ready
        coordinator.refresh(); await wait { calls == 5 }; await settle()
        precondition(note.titleSource == .transcriptExcerpt && note.title == "临时摘句内容")
        coordinator.refresh(); await settle()
        precondition(calls == 5, "Unavailable inference must not retry endlessly on refresh")
        output = "AI 整理后的主题"
        var updated = settings.ai; updated.model = "second-fixture"
        try settings.saveAI(updated, apiKey: "fixture-only")
        await wait { calls == 6 }; await settle()
        precondition(note.titleSource == .model && note.title == "AI 整理后的主题", "Model configuration changes retry and upgrade temporary titles")

        delayed = true
        note.applyTranscription(.init(text: "隐私撤回场景")); note.transcriptionState = .ready
        coordinator.refresh(); await wait { pending != nil }
        settings.requiresRemoteAIConfirmation = true
        precondition(lastCurrent?() == false, "Revocation invalidates an automatic provider request")
        pending?.resume(returning: "已撤回授权的旧标题"); pending = nil; await settle()
        precondition(note.needsRecordingTitle && note.title != "已撤回授权的旧标题", "A delayed provider cannot publish after consent revocation")
        settings.requiresRemoteAIConfirmation = false
        await wait { pending != nil }
        note.applyEdit(title: "生成期间手动命名", transcript: note.transcript)
        precondition(lastCurrent?() == false)
        pending?.resume(returning: "迟到标题"); pending = nil; await settle()
        precondition(note.title == "生成期间手动命名" && note.titleManuallyEdited == true, "A late title cannot overwrite a manual edit")

        // A new transcript without a manual title may queue again; a late old model result must be discarded.
        note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 1)
        note.applyTranscription(.init(text: "切换模型场景")); note.transcriptionState = .ready
        coordinator.refresh(); await wait { pending != nil }
        updated.model = "third-fixture"; try settings.saveAI(updated, apiKey: "fixture-only")
        precondition(lastCurrent?() == false)
        let old = pending; pending = nil; old?.resume(returning: "旧模型标题")
        await wait { pending != nil }
        precondition(note.title != "旧模型标题")
        pending?.resume(returning: "新模型标题"); pending = nil; await settle()
        precondition(note.displayTitle == "长录音·新模型标题")
        settings.requiresRemoteAIConfirmation = true
        note.applyTranscription(.init(text: "确认免提示后的失败场景")); note.transcriptionState = .ready
        delayed = false; output = nil
        let beforeManualFailure = calls
        await coordinator.generate(note.id, confirmation: coordinator.request(for: note.id), doNotAskAgain: true)
        await settle()
        precondition(calls == beforeManualFailure + 1, "One confirmed manual failure must not trigger an immediate automatic duplicate request")
        output = "重试生成的标题"
        await coordinator.generate(note.id)
        precondition(calls == beforeManualFailure + 2 && note.title == "重试生成的标题", "Explicit retry remains available after manual failure")
        settings.requiresRemoteAIConfirmation = true
        let remotePreview = coordinator.request(for: note.id)!
        updated.mode = .local
        try settings.saveAI(updated, apiKey: "")
        await coordinator.generate(note.id, confirmation: remotePreview, doNotAskAgain: true)
        await settle()
        precondition(calls == beforeManualFailure + 2 && settings.requiresRemoteAIConfirmation,
                     "A stale remote preview cannot authorize or generate after switching to local mode")
        print("Recording title coordinator: consent, automatic/manual generation, dedupe, temporary upgrade, stale text, manual edits, permission and model races passed")
    }
}
