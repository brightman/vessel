import Foundation

@MainActor final class FakeEngine: PhoneRecordingEngine {
    var onRecordingEnded: (() -> Void)?
    var onDraftUpdated: ((PhoneRecordingDraft) -> Void)?
    var recordingWarning: String?
    var active: PhoneRecordingDraft?
    var denied = false
    var capturedDuration: TimeInterval = 2
    var recoveryDuration: TimeInterval = 2
    var delay = false
    var gate: CheckedContinuation<Void, Never>?
    func startRecording(_ draft: PhoneRecordingDraft) async throws {
        if delay { await withCheckedContinuation { gate = $0 } }
        if denied { throw CocoaError(.userCancelled) }
        active = draft
    }
    func stopRecording() -> PhoneRecordingDraft? {
        guard let d = active else { return nil }; active = nil
        return PhoneRecordingDraft(id: d.id, fileURL: d.fileURL, duration: capturedDuration, capturedAt: d.capturedAt, location: d.location)
    }
    func discardRecording() { active = nil }
    func recordingWasSaved() {}
    func recoveredDuration(at url: URL) -> TimeInterval { recoveryDuration }
}
@MainActor final class FakeActivity: RecordingActivityManaging {
    var onDismiss: ((UUID) -> Void)?
    var unavailable = false
    var finished: [Bool] = []
    func start(sessionID: UUID, startedAt: Date) async throws { if unavailable { throw CocoaError(.featureUnsupported) } }
    func finish(sessionID: UUID, saved: Bool) async { finished.append(saved) }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FakeEngine(), activity = FakeActivity()
        var saved: [UUID] = []; var fail = true
        let store = PhoneRecordingDraftStore(root: root)
        let s = PhoneRecordingSession(engine: engine, activity: activity, store: store) { d in
            if fail { throw CocoaError(.fileWriteUnknown) }; saved.append(d.id)
        }
        try await s.start(requireLiveActivity: true)
        let id = engine.active!.id
        let point = CaptureLocation(latitude: 1, longitude: 2, measuredAt: .now, source: .phoneRecording)!
        engine.active?.location = point
        engine.onDraftUpdated?(engine.active!)
        let withPoint = try store.load()
        assert(withPoint.first?.location == point, "in-flight metadata writes to the session's actual draft store")
        try Data([1,2,3]).write(to: engine.active!.fileURL)
        try await s.start(requireLiveActivity: true)
        assert(engine.active!.id == id)
        try await s.stopAndSave(expectedSessionID: UUID())
        assert(engine.active != nil)
        do { try await s.stopAndSave(); assertionFailure("must fail persistence") } catch {}
        assert(s.phase == .failed && s.lastSaved == nil)
        let pending = try store.load(); assert(pending.count == 1)
        fail = false; try await s.retrySave()
        assert(saved == [id] && s.lastSaved?.id == id && s.lastSaved?.location == point)
        let empty = try store.load(); assert(empty.isEmpty)
        try await s.stopAndSave(); assert(saved.count == 1)
        activity.unavailable = true
        do { try await s.start(requireLiveActivity: true); assertionFailure() } catch {}
        assert(engine.active == nil)
        activity.unavailable = false
        try await s.start(requireLiveActivity: false)
        try Data([1]).write(to: engine.active!.fileURL)
        engine.onRecordingEnded?()
        for _ in 0..<30 { await Task.yield() }
        assert(saved.count == 2)
        engine.delay = true
        let starting = Task { try await s.start(requireLiveActivity: true) }
        for _ in 0..<30 { await Task.yield() }
        starting.cancel(); engine.gate?.resume()
        do { try await starting.value; assertionFailure() } catch {}
        assert(engine.active == nil)
        // Restart recovery reads the pre-capture manifest and finalized file duration.
        let recoveryRoot = root.appendingPathComponent("restart")
        let recoveryStore = PhoneRecordingDraftStore(root: recoveryRoot)
        let recovered = try recoveryStore.prepare(id: UUID(), at: .now)
        try Data([1]).write(to: recovered.fileURL)
        var recoveredIDs: [UUID] = []
        let restored = PhoneRecordingSession(engine: FakeEngine(), activity: FakeActivity(), store: recoveryStore) { recoveredIDs.append($0.id) }
        try await restored.recoverPendingRecordings()
        assert(recoveredIDs == [recovered.id] && restored.phase == .idle)
        // A stop submitted while microphone permission is pending waits for start.
        engine.delay = true
        let pendingStart = Task { try await s.start(requireLiveActivity: false) }
        for _ in 0..<30 { await Task.yield() }
        let pendingStop = Task { try await s.stopAndSave() }
        engine.gate?.resume()
        try await pendingStart.value; try await pendingStop.value
        assert(s.phase == .idle && engine.active == nil)
        engine.delay = false; engine.denied = true
        do { try await s.start(requireLiveActivity: true); assertionFailure() } catch {}
        assert(s.phase == .idle && engine.active == nil)
        engine.denied = false
        try await s.start(requireLiveActivity: true)
        activity.onDismiss?(s.currentSessionID!)
        for _ in 0..<30 { await Task.yield() }
        assert(s.phase == .idle)
        engine.capturedDuration = 0.1
        try await s.start(requireLiveActivity: false)
        let countBeforeShort = saved.count
        do { try await s.stopAndSave(); assertionFailure("short capture must fail") } catch {}
        assert(saved.count == countBeforeShort && s.lastSaved == nil)
        await s.discard()
        let protectedStore = PhoneRecordingDraftStore(root: root.appendingPathComponent("unreadable"))
        let unreadable = try protectedStore.prepare(id: UUID(), at: .now)
        try Data([1,2]).write(to: unreadable.fileURL)
        let noDuration = FakeEngine(); noDuration.recoveryDuration = 0
        var protectedSaves = 0
        let protected = PhoneRecordingSession(engine: noDuration, activity: FakeActivity(), store: protectedStore) { _ in protectedSaves += 1 }
        do { try await protected.recoverPendingRecordings(); assertionFailure() } catch {}
        assert(FileManager.default.fileExists(atPath: unreadable.fileURL.path))
        assert(protected.phase == .failed && protectedSaves == 0)
        noDuration.recoveryDuration = 3
        // Retrying after unlock must remeasure a prepared manifest with zero duration.
        noDuration.recoveryDuration = 0
        do { try await protected.retrySave(); assertionFailure() } catch {}
        noDuration.recoveryDuration = 3
        try await protected.retrySave()
        assert(protected.phase == .idle && protected.lastSaved?.duration == 3)
        // A transient initial store error must clear after a later successful empty scan.
        let badRoot = root.appendingPathComponent("blocked")
        try Data([1]).write(to: badRoot)
        let initiallyBlocked = PhoneRecordingSession(engine: FakeEngine(), activity: FakeActivity(), store: PhoneRecordingDraftStore(root: badRoot)) { _ in }
        assert(initiallyBlocked.phase == .failed)
        try FileManager.default.removeItem(at: badRoot)
        try await initiallyBlocked.retrySave()
        assert(initiallyBlocked.phase == .idle)
        // Relocation ignores serialized absolute paths, and cleanup stays under the current root.
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let oldStore = PhoneRecordingDraftStore(root: oldRoot)
        let old = try oldStore.prepare(id: UUID(), at: .now)
        try Data([7]).write(to: old.fileURL)
        try FileManager.default.copyItem(at: oldRoot, to: newRoot)
        let newStore = PhoneRecordingDraftStore(root: newRoot)
        let relocated = try newStore.load()[0]
        assert(relocated.fileURL.deletingLastPathComponent().path == newRoot.path)
        try newStore.remove(old)
        assert(FileManager.default.fileExists(atPath: old.fileURL.path))
        // Corrupt metadata cannot block independent valid recordings.
        let damagedRoot = root.appendingPathComponent("damaged")
        let damagedStore = PhoneRecordingDraftStore(root: damagedRoot)
        let valid = try damagedStore.prepare(id: UUID(), at: .now)
        try Data("{broken".utf8).write(to: damagedRoot.appendingPathComponent("broken.json"))
        let unaffected = try damagedStore.load()
        assert(unaffected.map(\.id) == [valid.id] && damagedStore.recoveryWarning != nil)
        // Legacy absolute URL metadata is ignored, including references outside the sandbox root.
        let legacy = PhoneRecordingDraft(id: valid.id, fileURL: old.fileURL, duration: 4, capturedAt: .now)
        try JSONEncoder().encode(legacy).write(to: damagedRoot.appendingPathComponent("\(valid.id.uuidString).json"))
        let safeLegacy = try damagedStore.load()[0]
        assert(safeLegacy.fileURL.path == damagedRoot.appendingPathComponent("\(valid.id.uuidString).m4a").path)
        // Initial quarantine must remain visible after runtime preparation scans again and after restart.
        let doubleScanRoot = root.appendingPathComponent("double-scan")
        try FileManager.default.createDirectory(at: doubleScanRoot, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: doubleScanRoot.appendingPathComponent("broken.json"))
        let doubleScan = PhoneRecordingSession(engine: FakeEngine(), activity: FakeActivity(), store: PhoneRecordingDraftStore(root: doubleScanRoot)) { _ in }
        assert(doubleScan.errorMessage?.contains("损坏") == true)
        try await doubleScan.recoverPendingRecordings()
        assert(doubleScan.errorMessage?.contains("损坏") == true)
        let nextLaunch = PhoneRecordingSession(engine: FakeEngine(), activity: FakeActivity(), store: PhoneRecordingDraftStore(root: doubleScanRoot)) { _ in }
        try await nextLaunch.recoverPendingRecordings()
        assert(nextLaunch.errorMessage?.contains("损坏") == true)
        // Interruption warning survives successful persistence.
        engine.capturedDuration = 2; engine.recordingWarning = "已保留中断前录音"
        try await s.start(requireLiveActivity: false)
        engine.onRecordingEnded?()
        for _ in 0..<30 { await Task.yield() }
        assert(s.errorMessage == engine.recordingWarning)
        // Action button: successive toggles start then save exactly the same capture.
        let toggleEngine = FakeEngine()
        var toggleSaved: [UUID] = []
        let toggles = PhoneRecordingSession(engine: toggleEngine, activity: FakeActivity(), store: PhoneRecordingDraftStore(root: root.appendingPathComponent("toggles"))) { toggleSaved.append($0.id) }
        try await toggles.toggle()
        assert(toggles.phase == .recording)
        let toggleID = toggles.currentSessionID!
        try await toggles.toggle()
        assert(toggles.phase == .idle && toggleSaved == [toggleID])
        // Two Action button invocations queue during suspended microphone startup.
        toggleEngine.delay = true
        let firstToggle = Task { try await toggles.toggle() }
        for _ in 0..<30 { await Task.yield() }
        assert(toggleEngine.gate != nil && toggles.phase == .starting)
        let queuedID = toggles.currentSessionID!
        let secondToggle = Task { try await toggles.toggle() }
        for _ in 0..<30 { await Task.yield() }
        toggleEngine.gate?.resume()
        try await firstToggle.value; try await secondToggle.value
        assert(toggles.phase == .idle && toggleEngine.active == nil)
        assert(toggleSaved == [toggleID, queuedID])
        print("PhoneRecordingSession tests passed")
    }
}
