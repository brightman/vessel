import AVFAudio
import Foundation
import SQLite3

@main
struct RecordingSessionRepositorySmoke {
    static let files = FileManager.default
    static let started = Date(timeIntervalSinceReferenceDate: 100)
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "RecordingSessionRepositorySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func fails(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "RecordingSessionRepositorySmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection"])
    }
    static func fixture(_ root: URL, phase: Double = 0) throws -> URL {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture-\(phase).m4a")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 16001)!
        pcm.frameLength = 16001
        for i in 0..<16001 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.1 + phase)) * 0.1 }
        try writer!.write(from: pcm); writer = nil
        return url
    }
    static func descriptor(_ audio: URL, session: UUID = UUID(), id: UUID = UUID(), ordinal: Int = 0,
                           offset: Double? = nil, frames: Int64 = 16001, zone: String = "UTC",
                           hash: String? = nil) throws -> RecordingChunkDescriptor {
        let info = try RecordingAudioFile.inspect(audio)
        return .init(id: id, sessionID: session, ordinal: ordinal, sessionStartedAt: started,
                     capturedAt: started.addingTimeInterval(offset ?? Double(ordinal) * 2), timeZoneIdentifier: zone,
                     sessionStartOffset: offset ?? Double(ordinal) * 2, frameCount: frames, sampleRate: 16000,
                     byteCount: info.byteCount, sha256: hash ?? info.sha256,
                     origin: .init(device: "Watch", deviceID: "synthetic", fileName: "../../untrusted.m4a", recordingTimeIsEstimated: false), location: nil)
    }
    static func repository(_ root: URL) throws -> (RecordingSessionRepository, DaybookDatabase) {
        let db = try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3"))
        return (try RecordingSessionRepository(root: root.appendingPathComponent("media"), database: db), db)
    }
    static func end(_ session: UUID, final: Int? = 2, revision: Int = 1, interrupted: Bool = false) -> RecordingSessionEnd {
        .init(sessionID: session, finalOrdinal: final, endedAt: started.addingTimeInterval(10), interrupted: interrupted, revision: revision)
    }
    // Missing coverage must never become ready just because the final file was saved.
    static func ordering(_ root: URL, _ audio: URL) throws {
        let (repo, db) = try repository(root), session = UUID()
        let two = try descriptor(audio, session: session, ordinal: 2)
        try repo.storeLocalChunk(two, from: audio)
        try repo.applyEnd(end(session))
        try expect(try repo.session(id: session)?.savedCount == 1, "one saved file")
        try expect(try repo.session(id: session)?.syncComplete == false, "missing prefix is incomplete")
        try expect(try repo.gaps(sessionID: session).contains { $0.kind == "missingChunks" }, "missing prefix visible")
        let zero = try descriptor(audio, session: session)
        let one = try descriptor(audio, session: session, ordinal: 1)
        try repo.storeLocalChunk(zero, from: audio)
        try repo.storeLocalChunk(one, from: audio)
        let savedRows = try db.query("SELECT * FROM recording_chunks ORDER BY ordinal")
        try repo.storeLocalChunk(one, from: audio)
        try expect(try db.query("SELECT * FROM recording_chunks ORDER BY ordinal") == savedRows, "duplicate preserves persisted chunk identity")
        try expect(try repo.session(id: session)?.savedCount == 3 && repo.session(id: session)?.syncComplete == true, "exact coverage ready")
        try expect(try repo.sessions().count == 1 && db.query("SELECT * FROM recording_chunks").count == 3, "one aggregate and one row per chunk")
        let ranges = try repo.sourceRanges(sessionID: session)
        try expect(ranges.map(\.chunkID) == [zero.id, one.id, two.id], "ordered ranges")
        try expect(ranges[1].startFrame == 0 && ranges[1].endFrame == 16001 && ranges[1].sessionStartOffset == 2, "effective frames and real offsets")
        try expect(ranges[1].discontinuityBefore != nil, "capture discontinuity retained")
        try expect(abs((try repo.session(id: session)!).recordedDuration - 3.0001875) < 0.000001, "encoder padding excluded")
        try repo.storeLocalChunk(one, from: audio)
        try repo.applyEnd(end(session))
        try expect(try repo.storedEnd(sessionID: session) == end(session), "exact end echo")
        let upper = try descriptor(audio, session: session, id: one.id, ordinal: 1, hash: one.sha256.uppercased())
        try repo.storeLocalChunk(upper, from: audio)
        try expect(try db.query("PRAGMA quick_check").first?["quick_check"]?.string == "ok", "database quick_check")
    }
    static func ends(_ root: URL, _ audio: URL) throws {
        let (repo, _) = try repository(root), session = UUID()
        try repo.applyEnd(end(session, final: 1))
        try expect(try repo.session(id: session)?.startedAt == nil, "end-first has no fabricated start")
        let one = try descriptor(audio, session: session, ordinal: 1)
        try repo.storeLocalChunk(one, from: audio)
        try expect(try repo.session(id: session)?.syncComplete == false, "missing first remains incomplete")
        try fails { try repo.applyEnd(end(session, final: 1, revision: 0)) }
        try fails { try repo.applyEnd(end(session, final: 1, interrupted: true)) }
        try fails { try repo.applyEnd(end(session, final: nil, revision: 2)) }
        try fails { try repo.storeLocalChunk(descriptor(audio, session: session, ordinal: 2), from: audio) }
        try repo.applyEnd(end(session, final: 1, revision: 2))
        let empty = UUID(); try repo.applyEnd(end(empty, final: nil))
        try expect(try repo.session(id: empty)?.syncComplete == true, "explicit zero audio end is complete")
        let noEnd = try descriptor(audio)
        try repo.storeLocalChunk(noEnd, from: audio)
        try expect(try repo.session(id: noEnd.sessionID)?.syncComplete == false, "no end never ready")
        let large = UUID(); try repo.applyEnd(end(large, final: 100000))
        try expect(try repo.gaps(sessionID: large).count == 1, "sparse large manifest represented as one gap")
        try expect(try repo.sessions(limit: 2).count == 2 && repo.sessions(limit: 2, offset: 2).count == 2, "bounded metadata pagination")
    }
    static func conflicts(_ root: URL, _ audio: URL, _ other: URL) throws {
        let (repo, _) = try repository(root), chunk = try descriptor(audio)
        try repo.storeLocalChunk(chunk, from: audio)
        let before = try Data(contentsOf: repo.sourceRanges(sessionID: chunk.sessionID)[0].url)
        try fails { try repo.storeLocalChunk(descriptor(other, session: chunk.sessionID, id: chunk.id), from: other) }
        try fails { try repo.storeLocalChunk(descriptor(audio, session: chunk.sessionID), from: audio) }
        try fails { try repo.storeLocalChunk(descriptor(audio, id: chunk.id), from: audio) }
        try fails { try repo.storeLocalChunk(descriptor(audio, session: chunk.sessionID, id: chunk.id, zone: "Asia/Singapore"), from: audio) }
        try fails { try repo.storeLocalChunk(descriptor(audio, session: chunk.sessionID, ordinal: 1, offset: 0.5), from: audio) }
        try fails { try repo.storeLocalChunk(descriptor(audio, frames: 100000), from: audio) }
        let link = root.appendingPathComponent("link.m4a")
        try files.createSymbolicLink(at: link, withDestinationURL: audio)
        try fails { try repo.storeLocalChunk(chunk, from: link) }
        try expect(try Data(contentsOf: repo.sourceRanges(sessionID: chunk.sessionID)[0].url) == before, "all conflicts preserve confirmed audio")
        try expect(files.fileExists(atPath: other.path), "conflict preserves sender inbox")
        let reversed = try descriptor(audio, ordinal: 1, offset: 1)
        try repo.storeLocalChunk(reversed, from: audio)
        try fails { try repo.storeLocalChunk(descriptor(audio, session: reversed.sessionID, offset: 0.5), from: audio) }
    }
    // Publication and COMMIT failures must retain an independent retry copy across reopen.
    static func recovery(_ root: URL, _ audio: URL) throws {
        for step in [RecordingSessionRepository.ImportStep.publish, .commit, .reclaim] {
            let folder = root.appendingPathComponent("\(step)"), chunk = try descriptor(audio)
            var (repo, db) = try repository(folder)
            try db.execute("CREATE TABLE commit_parent(id INTEGER PRIMARY KEY)")
            try db.execute("CREATE TABLE commit_child(id INTEGER REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED)")
            repo.importStep = { point in
                if point == step {
                    if step == .commit { try db.execute("INSERT INTO commit_child VALUES (99)") }
                    else { throw NSError(domain: "injected", code: 1) }
                }
            }
            if step == .reclaim { try repo.storeLocalChunk(chunk, from: audio) }
            else { try fails { try repo.storeLocalChunk(chunk, from: audio) } }
            try expect(files.fileExists(atPath: audio.path), "original input retained at every failure")
            try expect(try repo.session(id: chunk.sessionID)?.savedCount == (step == .reclaim ? 1 : nil), "no partial rows after failed transaction")
            repo.importStep = nil
            (repo, db) = try repository(folder)
            try expect(try repo.chunks(sessionID: chunk.sessionID).count == 1, "reopen replays retained journal")
            try expect(repo.consumeRecoveryChanges() == (step != .reclaim), "only a newly recovered commit invalidates content")
            try expect(!repo.consumeRecoveryChanges(), "recovery notification is consumed once")
            try expect(try repo.sourceRanges(sessionID: chunk.sessionID).count == 1, "recovered audio readable")
            try repo.storeLocalChunk(chunk, from: audio)
            try expect(try db.query("SELECT * FROM recording_chunks").count == 1, "restart and replay do not duplicate")
            try expect(try db.query("PRAGMA quick_check").first?["quick_check"]?.string == "ok", "recovery quick_check")
        }
        let folder = root.appendingPathComponent("bounded"), chunk = try descriptor(audio)
        let (repo, _) = try repository(folder)
        repo.importStep = { if $0 == .publish { throw NSError(domain: "publish", code: 1) } }
        for _ in 0..<5 { try fails { try repo.storeLocalChunk(chunk, from: audio) } }
        try expect(try files.contentsOfDirectory(atPath: folder.appendingPathComponent("media/Imports").path).count == 1, "identical failed retry uses one staging attempt")
    }
    static func deletion(_ root: URL, _ audio: URL) throws {
        var (repo, db) = try repository(root), chunk = try descriptor(audio)
        try repo.storeLocalChunk(chunk, from: audio)
        try repo.applyEnd(end(chunk.sessionID, final: 0))
        repo.importStep = { if $0 == .reclaim { throw NSError(domain: "cleanup", code: 1) } }
        try repo.deleteSession(chunk.sessionID)
        try expect(try db.query("SELECT * FROM recording_file_cleanup").count == 1, "failed deletion cleanup persists")
        try expect(try repo.cleanupPending(sessionID: chunk.sessionID) && repo.pendingCleanupSessionIDs() == [chunk.sessionID], "cleanup state exposed after tombstone")
        (repo, db) = try repository(root)
        try expect(repo.consumeRecoveryChanges(), "successful pending file cleanup still updates its status")
        try expect(try repo.session(id: chunk.sessionID) == nil && db.query("SELECT * FROM recording_file_cleanup").isEmpty, "reopen retries cleanup")
        try expect(try !repo.cleanupPending(sessionID: chunk.sessionID), "successful cleanup state cleared")
        try fails { try repo.storeLocalChunk(chunk, from: audio) }
        try fails { try repo.applyEnd(end(chunk.sessionID, final: 0)) }
        try expect(try db.query("SELECT * FROM recording_session_tombstones").count == 1, "deletion intent permanent")
        let absent = UUID(); try repo.deleteSession(absent)
        try fails { try repo.applyEnd(end(absent)) }
    }
    // Tombstones must cover published files whose failed transaction left no chunk row.
    static func deletionAfterFailedCommit(_ root: URL, _ audio: URL) throws {
        let (repo, db) = try repository(root), chunk = try descriptor(audio)
        repo.importStep = { if $0 == .commit { throw NSError(domain: "commit", code: 1) } }
        try fails { try repo.storeLocalChunk(chunk, from: audio) }
        repo.importStep = nil
        try repo.deleteSession(chunk.sessionID)
        _ = try repository(root)
        let finals = try files.contentsOfDirectory(atPath: root.appendingPathComponent("media/Audio").path)
        let stages = try files.contentsOfDirectory(atPath: root.appendingPathComponent("media/Imports").path)
        try expect(finals.isEmpty && stages.isEmpty, "deletion removes uncommitted published audio and staging")
        try expect(try db.query("SELECT * FROM recording_chunks").isEmpty, "orphan never resurrects")
    }

    static func datesAndMigration(_ root: URL, _ audio: URL) throws {
        let db = try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3"))
        let legacy = root.appendingPathComponent("legacy")
        try files.createDirectory(at: legacy.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: started, duration: 23400)
        note.title = "Manual title"; note.transcript = "Preserve full text"; note.speakerNames = ["speaker-1": "Manual name"]; note.ownerSpeakerIDs = ["speaker-1"]
        let legacyBytes = try JSONEncoder().encode([note])
        try legacyBytes.write(to: legacy.appendingPathComponent("notes.json"))
        let legacyAudio = legacy.appendingPathComponent("Audio/\(note.id.uuidString).m4a")
        try files.copyItem(at: audio, to: legacyAudio)
        _ = try NoteRepository(root: legacy, database: db)
        let originalRow = try db.query("SELECT * FROM voice_notes")
        for table in ["recording_end_receipts", "recording_receipts", "recording_gaps", "recording_chunks", "recording_sessions", "recording_file_cleanup", "recording_session_tombstones"] {
            try db.execute("DROP TABLE IF EXISTS \(table)")
        }
        try db.execute("PRAGMA user_version=4")
        let upgraded = try DaybookDatabase(url: db.url)
        let repo = try RecordingSessionRepository(root: root.appendingPathComponent("media"), database: upgraded)
        let freshVersion = try DaybookDatabase(inMemory: true).query("PRAGMA user_version")[0]["user_version"]
        try expect(try upgraded.query("PRAGMA user_version")[0]["user_version"] == freshVersion, "v4 upgraded to current schema")
        try expect(try upgraded.query("SELECT * FROM voice_notes") == originalRow, "legacy fields and payload unchanged")
        try expect(try NoteRepository(root: legacy, database: upgraded).notes == [note], "legacy note identity/full text/manual markers unchanged")
        try expect(try Data(contentsOf: legacyAudio) == Data(contentsOf: audio) && Data(contentsOf: legacy.appendingPathComponent("notes.json")) == legacyBytes, "legacy media/JSON bytes and path preserved")
        try expect(try repo.sessions().isEmpty, "legacy records not eagerly duplicated as sessions")
        let chunk = try descriptor(audio, offset: 86399.5)
        try repo.storeLocalChunk(chunk, from: audio)
        let nextDay = started.addingTimeInterval(86400)
        let found = try repo.sessions(overlapping: nextDay, end: nextDay.addingTimeInterval(86400))
        try expect(found.count == 1 && found[0].recordedIntervals.count == 1, "actual chunk overlap includes prior-start session")
        try expect(found[0].origin?.deviceID == "synthetic" && found[0].location == nil, "truthful source metadata")
        try expect(try repo.sessions(overlapping: nextDay.addingTimeInterval(2), end: nextDay.addingTimeInterval(86400)).isEmpty, "nonoverlapping tail excluded")
        let untimed = RecordingSessionEnd(sessionID: UUID(), finalOrdinal: nil, endedAt: nextDay.addingTimeInterval(100), interrupted: false, revision: 0)
        try repo.applyEnd(untimed)
        try expect(try repo.sessions(overlapping: nextDay.addingTimeInterval(2), end: nextDay.addingTimeInterval(86400)).isEmpty, "end-only session cannot invent occupied dates")
        _ = try DaybookDatabase(url: db.url)
        try expect(try upgraded.query("PRAGMA quick_check").first?["quick_check"]?.string == "ok", "migration/reopen quick_check")
        try upgraded.execute("PRAGMA user_version=999")
        try fails { _ = try DaybookDatabase(url: db.url) }
    }

    static func durabilityOrdering(_ root: URL, _ audio: URL) throws {
        let (repo, db) = try repository(root), chunk = try descriptor(audio)
        let observer = try DaybookDatabase(url: db.url)
        var events: [RecordingSessionRepository.ImportStep] = []
        var visibleCounts: [Int] = []
        repo.importStep = { step in
            events.append(step)
            let visible = try observer.query("SELECT * FROM recording_chunks").count
            visibleCounts.append(visible)
            if step == .commit {
                let url = root.appendingPathComponent("media/Audio/\(chunk.audioFilename)")
                _ = try RecordingAudioFile.validate(chunk, at: url)
            }
        }
        try repo.storeLocalChunk(chunk, from: audio)
        try expect(events == [.publish, .commit, .reclaim], "actual storage boundaries ordered")
        try expect(visibleCounts == [0, 0, 1], "external connection sees chunk only after COMMIT")
    }

    static func isolatedRecovery(_ root: URL, _ audio: URL) throws {
        let (repo, _) = try repository(root), chunk = try descriptor(audio)
        repo.importStep = { if $0 == .publish { throw NSError(domain: "publish", code: 1) } }
        try fails { try repo.storeLocalChunk(chunk, from: audio) }
        let broken = root.appendingPathComponent("media/Imports/broken")
        try files.createDirectory(at: broken, withIntermediateDirectories: true)
        let bad = Data("not JSON".utf8)
        try bad.write(to: broken.appendingPathComponent("manifest.json"))
        let reopened = try repository(root).0
        try expect(try reopened.chunks(sessionID: chunk.sessionID).count == 1, "bad independent journal cannot block valid recovery")
        try expect(reopened.recoveryIssues == ["broken"], "bad journal visible")
        try expect(try Data(contentsOf: broken.appendingPathComponent("manifest.json")) == bad, "invalid bytes retained")
        let linkedRoot = root.appendingPathComponent("linked")
        try files.createSymbolicLink(at: linkedRoot, withDestinationURL: root.appendingPathComponent("media"))
        let db = try DaybookDatabase(url: root.appendingPathComponent("other.sqlite3"))
        try fails { _ = try RecordingSessionRepository(root: linkedRoot, database: db) }
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]
        func record(_ key: String, _ value: Bool) { lock.lock(); defer { lock.unlock() }; values[key] = value }
        func value(_ key: String) -> Bool? { lock.lock(); defer { lock.unlock() }; return values[key] }
    }
    static func competingConnections(_ root: URL, _ audio: URL) throws {
        let (first, _) = try repository(root)
        let (second, db) = try repository(root)
        let chunk = try descriptor(audio)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0), group = DispatchGroup(), results = Outcomes()
        first.importStep = { if $0 == .commit {
            entered.signal(); _ = release.wait(timeout: .now() + 5)
            throw NSError(domain: "rollback-owner", code: 1)
        } }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try first.storeLocalChunk(chunk, from: audio); results.record("first", true) }
            catch { results.record("first", false) }
        }
        try expect(entered.wait(timeout: .now() + 5) == .success, "first reached publication before rollback")
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            secondStarted.signal()
            do { try second.storeLocalChunk(chunk, from: audio); results.record("second", true) }
            catch { results.record("second", false) }
        }
        _ = secondStarted.wait(timeout: .now() + 5); release.signal()
        try expect(group.wait(timeout: .now() + 10) == .success, "writers finished without deadlock")
        try expect(results.value("first") == false && results.value("second") == true, "second writer adopts retained publication after first rollback")
        try expect(try db.query("SELECT * FROM recording_chunks").count == 1 && second.sourceRanges(sessionID: chunk.sessionID).count == 1, "rollback cleanup cannot remove adopted media")
    }

    static func pendingIdentity(_ root: URL, _ audio: URL) throws {
        let (repo, _) = try repository(root), chunk = try descriptor(audio)
        repo.importStep = { if $0 == .publish { throw NSError(domain: "publish", code: 1) } }
        try fails { try repo.storeLocalChunk(chunk, from: audio) }
        repo.importStep = nil
        try fails { try repo.storeLocalChunk(descriptor(audio, session: chunk.sessionID), from: audio) }
        try repo.storeLocalChunk(chunk, from: audio)
        try expect(try repo.chunks(sessionID: chunk.sessionID).map(\.id) == [chunk.id], "retained pending identity wins over conflicting retry")
    }

    // Persist the exact pre-hourly filename format, as an upgrade would encounter it.
    static func legacyFilenames(_ root: URL, _ audio: URL) throws {
        let (repo, db) = try repository(root), chunk = try descriptor(audio)
        try repo.storeLocalChunk(chunk, from: audio)
        try repo.applyEnd(end(chunk.sessionID, final: 0))
        let directory = root.appendingPathComponent("media/Audio")
        let original = directory.appendingPathComponent(chunk.audioFilename)
        let legacyName = "\(chunk.sessionID.uuidString)_0000.m4a"
        let legacy = directory.appendingPathComponent(legacyName)
        try files.moveItem(at: original, to: legacy)
        try db.execute("UPDATE recording_chunks SET filename=? WHERE id=?", [.text(legacyName), .text(chunk.id.uuidString)])
        let rows = try db.query("SELECT * FROM recording_chunks")
        let bytes = try Data(contentsOf: legacy)
        let reopened = try repository(root).0
        do {
            try expect(try reopened.sessions().first?.savedCount == 1, "legacy session listed")
            try expect(try reopened.sourceRanges(sessionID: chunk.sessionID).first?.url == legacy, "legacy path is used for playback and ASR")
            try reopened.storeLocalChunk(chunk, from: audio)
            try expect(try db.query("SELECT * FROM recording_chunks") == rows, "reading/retry preserves old rows")
            try expect(try Data(contentsOf: legacy) == bytes && !files.fileExists(atPath: original.path), "legacy audio is neither renamed nor duplicated")
        } catch {
            throw NSError(domain: "RecordingSessionRepositorySmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Legacy filename upgrade must remain readable; got \(error)"])
        }
        // Neither a renamed foreign session nor a traversal path may bypass identity checks.
        for invalid in ["../" + legacyName, "\(UUID().uuidString)_0000.m4a", "\(chunk.sessionID.uuidString)_0001.m4a"] {
            try db.execute("UPDATE recording_chunks SET filename=? WHERE id=?", [.text(invalid), .text(chunk.id.uuidString)])
            try fails { _ = try reopened.chunks(sessionID: chunk.sessionID) }
        }
        try db.execute("UPDATE recording_chunks SET filename=? WHERE id=?", [.text(legacyName), .text(chunk.id.uuidString)])
        reopened.importStep = { if $0 == .reclaim { throw NSError(domain: "cleanup", code: 1) } }
        try reopened.deleteSession(chunk.sessionID)
        try expect(files.fileExists(atPath: legacy.path), "failed cleanup retains legacy bytes")
        let cleaned = try repository(root).0
        try expect(!files.fileExists(atPath: legacy.path), "reopen cleans tombstoned legacy filename")
        try expect(try !cleaned.cleanupPending(sessionID: chunk.sessionID), "legacy cleanup completes")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/recording-repository-\(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let audio = try fixture(root), other = try fixture(root, phase: 1)
        try legacyFilenames(root.appendingPathComponent("legacy-filenames"), audio)
        try ordering(root.appendingPathComponent("ordering"), audio)
        try ends(root.appendingPathComponent("ends"), audio)
        try conflicts(root.appendingPathComponent("conflicts"), audio, other)
        try recovery(root.appendingPathComponent("recovery"), audio)
        try deletion(root.appendingPathComponent("delete"), audio)
        try deletionAfterFailedCommit(root.appendingPathComponent("delete-failed"), audio)
        try datesAndMigration(root.appendingPathComponent("migration"), audio)
        try durabilityOrdering(root.appendingPathComponent("events"), audio)
        try isolatedRecovery(root.appendingPathComponent("isolated"), audio)
        try competingConnections(root.appendingPathComponent("concurrent"), audio)
        try pendingIdentity(root.appendingPathComponent("pending-identity"), audio)
        print("RecordingSessionRepositorySmoke passed: ordering, sparse gaps, conflicts, COMMIT/publication/reclamation recovery, deletion and ranges")
    }
}
