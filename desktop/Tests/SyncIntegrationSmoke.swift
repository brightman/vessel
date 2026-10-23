import Foundation
import Network

@main struct SyncIntegrationSmoke {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw DesktopSyncError.invalid("Test failed: " + message) }
    }
    static func reject(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw DesktopSyncError.invalid("Test failed: rejected operation succeeded")
    }
    static func note(_ id: UUID = UUID(), text: String = "确定下周完成桌面同步测试。") -> VoiceNote {
        var note = VoiceNote(id: id, kind: .long, capturedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 60)
        note.title = "同步测试"
        note.applyTranscription(.init(text: text, segments: [.init(start: 1, end: 5, text: text, speakerID: "speaker-1")]))
        note.transcriptionState = .ready; note.diarizationState = .ready
        note.speakerNames = ["speaker-1": "PRIVATE_CONTACT_NAME"]
        return note
    }
    static func insert(_ note: VoiceNote, _ db: DaybookDatabase) throws {
        try db.execute("INSERT INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES (?,?,?,?,?,?,?,?,?)", [.text(note.id.uuidString), .real(note.capturedAt.timeIntervalSinceReferenceDate), .text(note.kind.rawValue), .text(note.title), .text(note.transcript), .text(note.summary), .real(note.duration), .text(note.audioFilename), try DaybookDatabase.json(note)])
    }
    static func update(_ note: VoiceNote, _ db: DaybookDatabase) throws {
        try db.execute("UPDATE voice_notes SET transcript=?,title=?,payload=? WHERE id=?", [.text(note.transcript), .text(note.title), try DaybookDatabase.json(note), .text(note.id.uuidString)])
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiselife-sync-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DaybookDatabase(url: directory.appendingPathComponent("phone.sqlite3"))
        let phone = PhoneDesktopSyncRepository(database: db)
        let store = try DesktopStore(url: directory.appendingPathComponent("desktop.sqlite3"))
        let identity = try DesktopTLSIdentity.ephemeral(), serverID = UUID().uuidString
        let server = DesktopSyncServer(serverID: serverID, identity: identity, store: store)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.onReady = { continuation.resume(returning: $0) }
            do { try server.start() } catch { continuation.resume(throwing: error) }
        }
        defer { server.stop() }
        let code = await server.pairingCode(host: "127.0.0.1", port: port)
        try check(DesktopPairingCode.parse(code.url).url == code.url, "pairing code roundtrip")
        for n in 0..<1000 {
            let record = DesktopTranscript(id: "legacyNote:" + UUID().uuidString, title: "日期", capturedAt: Date(timeIntervalSince1970: 1_700_000_000.123 + Double(n) * 0.00017), duration: 1, captureDevice: "iPhone", kind: "long", text: "文字", spans: [], isFinal: true)
            try check(DesktopSyncCodec.decode(DesktopTranscript.self, DesktopSyncCodec.encode(record)).contentHash == record.contentHash, "timestamp hash is stable across serialization")
        }
        let deviceID = try phone.deviceID()
        try check(PhoneDesktopSyncRepository(database: DaybookDatabase(url: db.url)).deviceID() == deviceID, "phone identity survives reopen")
        let pair = DesktopSyncRequest(operation: "pair", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: code.secret)
        let paired = try await SyncConnection.exchange(pair, code: code)
        guard let token = paired.deviceToken else { throw DesktopSyncError.invalid("Pair did not return token") }
        try await reject { _ = try await SyncConnection.exchange(pair, code: code) }
        let wrongPin = DesktopPairingCode(serverID: serverID, name: "Fixture Mac", host: "127.0.0.1", port: port, certificateHash: String(repeating: "0", count: 64), secret: code.secret, expiresAt: .now.addingTimeInterval(60))
        try await reject { _ = try await SyncConnection.exchange(pair, code: wrongPin) }
        print("PASS: TLS certificate pinning, one-use pairing and durable device identity")
        var original = note()
        try insert(original, db); try phone.reconcile()
        let event = try phone.events(after: 0)
        try check(event.count == 1 && event[0].record?.spans.first?.start == 1, "timestamps projected")
        let projected = String(data: try DesktopSyncCodec.encode(event), encoding: .utf8)!
        try check(!projected.contains("PRIVATE_CONTACT_NAME") && !projected.contains("audioFilename") && !projected.contains("speakerContacts"), "projection excludes contact metadata and audio")
        var request = DesktopSyncRequest(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: token, events: event)
        let reply = try await SyncConnection.exchange(request, code: code)
        try phone.accept(reply, serverID: serverID, maximumSent: event.last!.sequence)
        _ = try await SyncConnection.exchange(request, code: code)
        try check(store.items().count == 1 && phone.state(serverID: serverID).pending == 0, "replay deduplicated and acknowledged")
        var bad = request; bad = DesktopSyncRequest(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: "wrong")
        try await reject { _ = try await SyncConnection.exchange(bad, code: code) }
        let item = try store.items()[0]
        let summary = DesktopSummary(id: UUID(), recordID: item.transcript.id, inputHash: item.transcript.contentHash, model: "Fixture local model", generatedAt: .now, markdown: "## 概览\n下周完成测试。 [S1]", references: [.init(id: "S1", start: 1, end: 5, speaker: "说话人 1", text: original.transcript)])
        try store.save(summary, item: item)
        request = .init(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: token)
        let summarized = try await SyncConnection.exchange(request, code: code)
        try phone.accept(summarized, serverID: serverID, maximumSent: reply.acknowledged)
        try check(phone.summaries()[item.transcript.id]?.id == summary.id, "desktop summary roundtrip saved on phone")
        original.applyEdit(title: original.title, transcript: "修改后的文字")
        try update(original, db)
        try check(phone.summaries().isEmpty, "phone immediately hides stale summary")
        let revisedEvents = try phone.events(after: reply.acknowledged)
        request = .init(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: token, events: revisedEvents)
        let revisedReply = try await SyncConnection.exchange(request, code: code)
        try phone.accept(revisedReply, serverID: serverID, maximumSent: revisedEvents.last!.sequence)
        try check(store.items()[0].summary == nil && store.items()[0].transcript.text == "修改后的文字", "desktop invalidates old summary")
        try await reject { try store.save(summary, item: item) }
        print("PASS: phone → Mac → phone, replay, speaker privacy, edits and stale-result rejection")
        let count = try phone.events(after: 0).count
        do { try db.transaction { try db.execute("DELETE FROM voice_notes"); throw DesktopSyncError.storage } } catch { }
        try phone.reconcile(); try check(phone.events(after: 0).count == count, "rollback does not publish deletion")
        try db.execute("DELETE FROM voice_notes WHERE id=?", [.text(original.id.uuidString)]); try phone.reconcile()
        let deletion = try phone.events(after: revisedReply.acknowledged)
        try check(deletion.count == 1 && deletion[0].record == nil, "deletion tombstone")
        try check(!db.query("SELECT sequence FROM desktop_sync_events WHERE payload IS NOT NULL").contains { _ in true }, "deleted source text removed from journal")
        request = .init(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: token, events: deletion)
        _ = try await SyncConnection.exchange(request, code: code)
        try check(store.items().isEmpty, "deletion reaches desktop")
        print("PASS: transaction rollback, source deletion and journal text cleanup")
        try sessionFixture(phone, db)
        let reopened = try PhoneDesktopSyncRepository(database: DaybookDatabase(url: db.url))
        try check(reopened.events(after: 0).contains { $0.record?.id.hasPrefix("session:") == true }, "session projection survives reopen")
        print("PASS: V2 sessions retain original timeline and do not duplicate derived segments")
        try await modelFixture(store, directory: directory)
        request = .init(operation: "unpair", serverID: serverID, deviceID: deviceID, deviceName: "Fixture iPhone", credential: token)
        _ = try await SyncConnection.exchange(request, code: code)
        try check(store.devices().isEmpty && store.items().isEmpty, "unpair deletes desktop data")
        _ = try await SyncConnection.exchange(request, code: code)
        request = .init(operation: "exchange", serverID: serverID, deviceID: deviceID, deviceName: "Fixture", credential: token)
        try await reject { _ = try await SyncConnection.exchange(request, code: code) }
        print("PASS: unpair revokes credential and deletes desktop copies")
        print("All desktop sync integration checks passed.")
    }
    static func sessionFixture(_ phone: PhoneDesktopSyncRepository, _ db: DaybookDatabase) throws {
        let id = AudioSourceID(kind: .session, id: UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(id.id.uuidString)])
        let chunk = UUID()
        let range = try AudioSourceRange(range: .init(chunkID: chunk, url: URL(fileURLWithPath: "/synthetic/session.m4a"), startFrame: 0, endFrame: 160_000, sampleRate: 16_000, sessionStartOffset: 25, discontinuityBefore: "missing"), contentHash: String(repeating: "a", count: 64))
        let source = try AudioSourceSnapshot(id: id, capturedAt: .now, title: "会话", ranges: [range], complete: true)
        let processing = AudioProcessingRepository(database: db)
        try processing.register(source: source, configurationKey: "fixture", windows: AudioWindowPlanner.plan(source: source, configurationKey: "fixture"))
        while let job = try processing.claimNext() {
            try processing.commit(job: job, result: .init(spans: [.init(start: 26, end: 29, text: "会话片段", speakerID: "speaker-1")], activities: [], asr: .success, vad: .success, speaker: .notRequested, asrCoverage: [.init(start: 25, end: 35)], vadCoverage: [.init(start: 25, end: 35)]))
        }
        try phone.reconcile()
        let record = try phone.project(id.key)
        try check(record?.spans.first?.start == 26 && record?.isFinal == true, "session source offsets preserved")
        try check(db.query("SELECT record_id FROM desktop_sync_projection").count == 1, "only source record projected")
    }
    static func modelFixture(_ store: DesktopStore, directory: URL) async throws {
        guard let raw = ProcessInfo.processInfo.environment["WISELIFE_TEST_MODEL_PORT"], let port = UInt16(raw) else { throw DesktopSyncError.invalid("Missing fixture port") }
        let id = UUID().uuidString, token = try store.pair(deviceID: id, name: "Model fixture")
        let record = DesktopTranscript(id: "legacyNote:" + UUID().uuidString, title: "长录音", capturedAt: .now, duration: 3600, captureDevice: "iPhone", kind: "long", text: String(repeating: "这是完整测试资料，请保留所有内容。", count: 2400), spans: [], isFinal: true)
        _ = try store.exchange(.init(operation: "exchange", serverID: "fixture", deviceID: id, deviceName: "Fixture", credential: token, events: [.init(sequence: 1, recordID: record.id, record: record)]), serverID: "fixture")
        let item = try store.items()[0]
        var configuration = DesktopModelConfiguration(baseURL: "http://127.0.0.1:\(port)/v1", model: "fixture", autoSummarize: false)
        let service = DesktopModelService()
        try check(DesktopModelService.chunks(DesktopModelService.sources(record)).count > 1, "long text segmented")
        let models = try await service.models(configuration: configuration, key: "")
        try check(models == ["fixture"], "local model discovery")
        let summary = try await service.summarize(item: item, configuration: configuration, key: "", store: store, progress: { _ in })
        try store.save(summary, item: item)
        try check(summary.references.count == 1 && summary.references[0].id == "S1", "bounded source references")
        _ = try await service.summarize(item: item, configuration: configuration, key: "", store: store, progress: { _ in })
        configuration.model = "invalid-citation"
        let invalid = configuration
        try await reject { _ = try await service.summarize(item: item, configuration: invalid, key: "", store: store, progress: { _ in }) }
        configuration.baseURL = "https://example.com/v1"
        let external = configuration
        try await reject { _ = try external.endpoint("models") }
        var custom = configuration; custom.mode = .custom
        try check(custom.endpoint("models").scheme == "https", "explicit custom mode accepts HTTPS")
        custom.baseURL = "http://example.com/v1"
        let insecure = custom
        try await reject { _ = try insecure.endpoint("models") }
        configuration.baseURL = "http://127.0.0.1:\(port)/redirect/v1"; configuration.model = "fixture"
        let redirect = configuration
        try await reject { try await service.test(configuration: redirect, key: "") }
        try store.revoke(id)
        try await reject { try store.save(summary, item: item) }
        print("PASS: loopback model API, long-text checkpoints, citations, redirect refusal and revoked-source guards")
    }
}
