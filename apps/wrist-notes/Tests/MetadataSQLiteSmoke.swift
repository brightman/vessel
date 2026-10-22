import Foundation
import SQLite3

private final class RollbackAction {
    let action: () throws -> Void
    var count = 0
    var error: Error?
    init(_ action: @escaping () throws -> Void) { self.action = action }
    func run() { count += 1; do { try action() } catch { self.error = error } }
}

@main
struct MetadataSQLiteSmoke {
    static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "MetadataSQLiteSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static let files = FileManager.default
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0, 2, 0xff, 0xd9])
    static func failure(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw NSError(domain: "MetadataSQLiteSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "expected failure"])
    }
    static func db(_ root: URL) throws -> DaybookDatabase { try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3")) }
    static func write<T: Encodable>(_ value: T, _ root: URL, _ filename: String) throws -> Data {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: root.appendingPathComponent(filename)); return data
    }
    static func voice(_ root: URL) throws {
        var note = VoiceNote(id: UUID(), kind: .thought, capturedAt: Date(timeIntervalSinceReferenceDate: -12345), duration: 12)
        note.title = "literal title"; note.transcript = "literal transcript"; note.summary = "literal summary"
        note.transcriptionState = .ready; note.summaryState = .failed; note.processingMessage = "literal processing"
        note.origin = RecordingOrigin(device: "EurekaRing", deviceID: "literal-device", fileName: "source.wav", recordingTimeIsEstimated: true)
        note.transcriptSegments = [TranscriptSegment(start: 0, end: 1.5, text: "literal segment", speakerID: "speaker-1")]
        note.speakerNames = ["speaker-1": "阿明", "speaker-2": ""]; note.ownerSpeakerIDs = ["speaker-1"]
        note.voiceIdentityMessage = "literal identity"; note.diarizationState = .unavailable; note.diarizationMessage = "literal diarization"; note.transcriptRevision = UUID()
        let old = try write([note], root, "notes.json")
        let a = try NoteRepository(root: root), b = try NoteRepository(root: root)
        try expect(a.notes == [note] && b.notes == [note], "all Codable voice fields survive migration and reopen without media")
        try a.update(id: note.id) { $0.title = "new title" }
        try b.update(id: note.id) { $0.summary = "new summary" }
        let reopened = try NoteRepository(root: root)
        try expect(reopened.notes[0].title == "new title" && reopened.notes[0].summary == "new summary", "stale instance updates current target row")
        try expect(try Data(contentsOf: root.appendingPathComponent("notes.json")) == old, "voice JSON preserved")
        let database = try db(root)
        try database.execute("CREATE TRIGGER voice_fail BEFORE UPDATE ON voice_notes BEGIN SELECT RAISE(ABORT,'injected'); END")
        let before = reopened.notes
        try failure { try reopened.update(id: note.id) { $0.title = "must fail" } }
        try expect(reopened.notes == before && (try NoteRepository(root: root)).notes == before, "voice write failure preserves published and durable state")
        try database.execute("DROP TRIGGER voice_fail")
        // A reload failure must happen before COMMIT; candidate files and rows roll back together.
        try database.execute("CREATE TRIGGER corrupt_voice AFTER INSERT ON voice_notes BEGIN UPDATE voice_notes SET title='bad projection' WHERE id=NEW.id; END")
        let failedSource = root.appendingPathComponent("failed-draft.m4a"); try Data([8]).write(to: failedSource)
        let failedID = UUID()
        try failure { _ = try reopened.importRecording(id: failedID, from: failedSource, kind: .long, capturedAt: .now, duration: 1) }
        try expect(files.fileExists(atPath: failedSource.path) && !files.fileExists(atPath: root.appendingPathComponent("Audio/\(failedID).m4a").path), "reload failure retains draft and removes uncommitted candidate")
        try expect(try database.query("SELECT id FROM voice_notes").count == 1, "reload failure rolls back insert")
        try database.execute("DROP TRIGGER corrupt_voice")
        // Keep media after the SQL delete to model interruption before cleanup; reopen must retry cleanup, not resurrect.
        try reopened.delete(id: note.id)
        let audio = root.appendingPathComponent("Audio/\(note.audioFilename)")
        try Data([1,2,3]).write(to: audio)
        try expect(try NoteRepository(root: root).notes.isEmpty, "tombstone suppresses orphan recovery")
        try expect(!files.fileExists(atPath: audio.path), "reopen retries tombstone cleanup")
        let source = root.appendingPathComponent("transfer.m4a"); try Data([4,5]).write(to: source)
        _ = try reopened.importRecording(id: note.id, from: source, kind: .thought, capturedAt: .now, duration: 1)
        try files.removeItem(at: audio); try Data([6,7]).write(to: source)
        _ = try a.importRecording(id: note.id, from: source, kind: .thought, capturedAt: .now, duration: 1)
        try expect(try Data(contentsOf: audio) == Data([6,7]), "repeat UUID restores missing audio")
        try expect(try database.query("SELECT id FROM voice_notes").count == 1, "repeat UUID retains one row")
        try database.execute("UPDATE voice_notes SET title='corrupt projection'")
        try failure { _ = try NoteRepository(root: root) }
    }
    static func rollbackCleanupOwnership(_ root: URL) throws {
        let firstDB = try db(root), secondDB = try db(root)
        let first = try NoteRepository(root: root, database: firstDB)
        let second = try NoteRepository(root: root, database: secondDB)
        let id = UUID(), failedSource = root.appendingPathComponent("failed-source.m4a"), acceptedSource = root.appendingPathComponent("accepted-source.m4a")
        try Data([1,2,3]).write(to: failedSource); try Data([4,5,6]).write(to: acceptedSource)
        try firstDB.execute("CREATE TRIGGER fail_first_transfer BEFORE INSERT ON voice_notes WHEN NEW.captured_at=10 BEGIN SELECT RAISE(ABORT,'injected'); END")
        // SQLite profiles ROLLBACK after releasing its write lock but before transaction() returns.
        // The independent connection can now durably adopt the first import's candidate file.
        let handoff = RollbackAction {
            _ = try second.importRecording(id: id, from: acceptedSource, kind: .long, capturedAt: Date(timeIntervalSinceReferenceDate: 20), duration: 1)
        }
        _ = try firstDB.withConnection { connection in
            sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)), String(cString: sql) == "ROLLBACK" else { return 0 }
                Unmanaged<RollbackAction>.fromOpaque(context).takeUnretainedValue().run()
                return 0
            }, Unmanaged.passUnretained(handoff).toOpaque())
        }
        defer { _ = try? firstDB.withConnection { sqlite3_trace_v2($0, 0, nil, nil) } }
        try failure { _ = try first.importRecording(id: id, from: failedSource, kind: .long, capturedAt: Date(timeIntervalSinceReferenceDate: 10), duration: 1) }
        try expect(handoff.count == 1 && handoff.error == nil, "second connection imports in rollback cleanup interval")
        try expect(try NoteRepository(root: root).notes.count == 1, "second import remains durable")
        let audio = root.appendingPathComponent("Audio/\(id).m4a")
        try expect(files.fileExists(atPath: audio.path), "failed import cleanup must preserve audio adopted by a committed second import")
        try expect(try Data(contentsOf: audio) == Data([1,2,3]), "adopted candidate audio remains intact")
        try expect(files.fileExists(atPath: failedSource.path), "failed import retains caller draft")
    }
    static func unsafeVoiceMedia(_ root: URL) throws {
        let store = try NoteRepository(root: root)
        let note = VoiceNote(id: UUID(), kind: .thought, capturedAt: .now, duration: 1)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        object["audioFilename"] = "../outside.m4a"
        let forged = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(store.audioURL(for: forged).lastPathComponent == "\(note.id.uuidString).m4a", "public audio URL never incorporates an untrusted filename")
        let legacy = root.appendingPathComponent("unsafe-legacy"); _ = try write([forged], legacy, "notes.json")
        try failure { _ = try NoteRepository(root: legacy) }
        let source = root.appendingPathComponent("source.m4a"); try Data([1]).write(to: source)
        let saved = try store.importRecording(id: note.id, from: source, kind: .long, capturedAt: .now, duration: 1)
        try store.delete(id: saved.id)
        let outside = root.appendingPathComponent("outside.m4a"); try Data([9]).write(to: outside)
        let audio = store.audioURL(for: saved)
        try files.createSymbolicLink(at: audio, withDestinationURL: outside)
        try expect(try NoteRepository(root: root).notes.isEmpty, "tombstoned symlink is not read or recovered")
        try expect(try Data(contentsOf: outside) == Data([9]), "cleanup never follows media symlink")
        try files.removeItem(at: audio); try Data([2]).write(to: audio)
        _ = try NoteRepository(root: root)
        try expect(!files.fileExists(atPath: audio.path), "cleanup can retry once unsafe media is repaired")
    }
    static func migrationRetry(_ root: URL) throws {
        let one = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 1)
        let two = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 1)
        let old = try write([one,two], root, "notes.json"), database = try db(root)
        try database.execute("CREATE TRIGGER migrate_fail BEFORE INSERT ON voice_notes WHEN NEW.id='\(two.id.uuidString)' BEGIN SELECT RAISE(ABORT,'injected'); END")
        try failure { _ = try NoteRepository(root: root) }
        try expect(try database.query("SELECT id FROM voice_notes").isEmpty, "migration rolls back first inserted row")
        try expect(try database.query("SELECT domain FROM storage_migrations").isEmpty, "failed migration has no marker")
        try expect(try Data(contentsOf: root.appendingPathComponent("notes.json")) == old, "failed migration preserves JSON")
        try database.execute("DROP TRIGGER migrate_fail")
        try expect(try NoteRepository(root: root).notes.count == 2, "failed migration can retry")
        let bad = root.appendingPathComponent("bad"); try files.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("bad JSON".utf8).write(to: bad.appendingPathComponent("notes.json"))
        try failure { _ = try NoteRepository(root: bad) }
        _ = try write([one], bad, "notes.json")
        try expect(try NoteRepository(root: bad).notes == [one], "repaired JSON retries migration")
        let duplicate = root.appendingPathComponent("duplicate"); _ = try write([one,one], duplicate, "notes.json")
        try failure { _ = try NoteRepository(root: duplicate) }
        let invalid = root.appendingPathComponent("invalid")
        _ = try write([VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: -1)], invalid, "notes.json")
        try failure { _ = try NoteRepository(root: invalid) }
    }
    static func photos(_ root: URL) throws {
        let p1 = UUID(), p2 = UUID()
        let moment = PhotoMoment(id: UUID(), capturedAt: Date(timeIntervalSinceReferenceDate: 25), caption: "literal caption", recognizedText: "literal OCR", photos: [PhotoAttachment(id: p1, filename: "\(p1).jpg", recognizedText: "literal OCR"), PhotoAttachment(id: p2, filename: "\(p2).jpg", recognizedText: "", recognitionError: "literal error")])
        let old = try write([moment], root, "moments.json"), database = try db(root)
        try database.execute("CREATE TRIGGER attachment_fail BEFORE INSERT ON photo_attachments WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'injected'); END")
        try failure { _ = try PhotoRepository(root: root) }
        try expect(try database.query("SELECT id FROM photo_moments").isEmpty && database.query("SELECT id FROM photo_attachments").isEmpty, "photo migration is atomic")
        try expect(try database.query("SELECT domain FROM storage_migrations").isEmpty, "photo failure does not mark migration")
        try database.execute("DROP TRIGGER attachment_fail")
        let a = try PhotoRepository(root: root), b = try PhotoRepository(root: root)
        try expect(a.moments == [moment], "multiple attachments, order, OCR errors and missing images survive migration")
        try failure { _ = try a.imageURL(for: moment.photos[0]) }
        try database.execute("CREATE TRIGGER keep_photo BEFORE DELETE ON photo_moments WHEN OLD.id='\(moment.id)' BEGIN SELECT RAISE(ABORT,'unrelated'); END")
        let saved = try b.save(caption: "new", photos: [PhotoImport(jpegData: jpeg)])
        try a.delete(id: saved.id)
        try expect(a.moments == [moment], "targeted delete preserves unrelated row")
        try expect(try Data(contentsOf: root.appendingPathComponent("moments.json")) == old, "photo JSON unchanged")
        try database.execute("DROP TRIGGER keep_photo")
        try database.execute("CREATE TRIGGER attachment_fail BEFORE INSERT ON photo_attachments WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'injected'); END")
        try failure { _ = try a.save(caption: "fail", photos: [PhotoImport(jpegData: jpeg),PhotoImport(jpegData: jpeg)]) }
        try expect(a.moments == [moment] && (try PhotoRepository(root: root)).moments == [moment], "failed attachment insert preserves state")
        try expect(try files.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty, "failed photo save removes candidate media")
        try database.execute("DROP TRIGGER attachment_fail")
        try database.execute("CREATE TRIGGER corrupt_attachment AFTER INSERT ON photo_attachments BEGIN UPDATE photo_attachments SET position=5 WHERE id=NEW.id; END")
        try failure { _ = try a.save(caption: "decode must fail before commit", photos: [PhotoImport(jpegData: jpeg)]) }
        try expect(try files.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty, "photo reload failure cleans only uncommitted media")
        try expect(try database.query("SELECT id FROM photo_moments").count == 1, "photo reload failure rolls back candidate row")
        try database.execute("DROP TRIGGER corrupt_attachment")
        let duplicate = root.appendingPathComponent("duplicate"); _ = try write([moment,moment], duplicate, "moments.json")
        try failure { _ = try PhotoRepository(root: duplicate) }
        let bad = root.appendingPathComponent("bad"); try files.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: bad.appendingPathComponent("moments.json")); try failure { _ = try PhotoRepository(root: bad) }
        _ = try write([moment], bad, "moments.json"); try expect(try PhotoRepository(root: bad).moments == [moment], "photo repaired JSON retries")
    }
    static func reminder(_ id: UUID = UUID()) -> DaybookReminder {
        DaybookReminder(id: id, title: "literal reminder", scheduledAt: Date(timeIntervalSinceReferenceDate: 50000), sourceID: UUID(), status: .needsAttention, notificationID: DaybookReminder.notificationPrefix + id.uuidString, createdAt: Date(timeIntervalSinceReferenceDate: 10), updatedAt: Date(timeIntervalSinceReferenceDate: 20))
    }
    static func reminders(_ root: URL) throws {
        let one = reminder(), two = reminder(), old = try write([one], root, "reminders.json")
        let a = try DaybookReminderRepository(root: root), b = try DaybookReminderRepository(root: root)
        try expect(a.items == [one], "reminder fields migrate exactly")
        try a.replace(with: [one,two])
        var edited = one; edited.title = "edited"
        try b.replace(with: [edited])
        try expect(Set(try DaybookReminderRepository(root: root).items.map(\.id)) == [one.id,two.id], "replacement diff preserves unseen additions")
        let beforeStaleDelete = a.items
        try failure { try a.replace(with: [two]) }
        try expect(a.items == beforeStaleDelete, "stale delete rejected without publishing")
        let database = try db(root)
        try database.execute("CREATE TRIGGER keep_reminder BEFORE DELETE ON daybook_reminders WHEN OLD.id='\(two.id)' BEGIN SELECT RAISE(ABORT,'unrelated'); END")
        edited.title = "edited twice"; try b.replace(with: [edited,two])
        try expect(try Data(contentsOf: root.appendingPathComponent("reminders.json")) == old, "reminder JSON unchanged")
        let retry = root.appendingPathComponent("retry"), retryDB = try db(retry)
        let retryBytes = try write([one,two], retry, "reminders.json")
        try retryDB.execute("CREATE TRIGGER fail_reminder_migration BEFORE INSERT ON daybook_reminders WHEN NEW.id='\(two.id)' BEGIN SELECT RAISE(ABORT,'injected'); END")
        try failure { _ = try DaybookReminderRepository(root: retry) }
        try expect(try retryDB.query("SELECT id FROM daybook_reminders").isEmpty && retryDB.query("SELECT domain FROM storage_migrations").isEmpty, "reminder import and marker roll back together")
        try expect(try Data(contentsOf: retry.appendingPathComponent("reminders.json")) == retryBytes, "failed reminder migration leaves JSON bytes unchanged")
        try retryDB.execute("DROP TRIGGER fail_reminder_migration")
        try expect(try DaybookReminderRepository(root: retry).items.count == 2, "reminder failed SQL migration retries")
        let dup = root.appendingPathComponent("dup"); _ = try write([one,one], dup, "reminders.json")
        try failure { _ = try DaybookReminderRepository(root: dup) }
        let bad = root.appendingPathComponent("bad"); try files.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: bad.appendingPathComponent("reminders.json")); try failure { _ = try DaybookReminderRepository(root: bad) }
        _ = try write([one], bad, "reminders.json"); try expect(try DaybookReminderRepository(root: bad).items == [one], "reminder repaired JSON retries")
    }
    static func schema(_ root: URL) throws {
        let database = try db(root)
        for (table,column) in [("voice_notes","captured_at"),("photo_moments","captured_at"),("daybook_reminders","scheduled_at")] {
            let plan = try database.query("EXPLAIN QUERY PLAN SELECT * FROM \(table) ORDER BY \(column),id")
            try expect(plan.contains { $0["detail"]?.string?.contains("USING INDEX") == true }, "ordered scan uses date index: \(table)")
        }
        try database.execute("INSERT INTO life_suppression(id) VALUES ('v1 sentinel')")
        try database.execute("CREATE TABLE extension_sentinel (value TEXT)")
        try database.execute("INSERT INTO extension_sentinel VALUES ('extension data')")
        // Remove every v2 object to reconstruct a real v1 schema before reopening.
        for table in ["reminder_apple_links", "photo_attachments", "photo_moments", "voice_notes", "daybook_reminders", "media_tombstones"] {
            try database.execute("DROP TABLE \(table)")
        }
        try database.execute("PRAGMA user_version=1")
        let upgraded = try db(root)
        for table in ["voice_notes", "photo_moments", "photo_attachments", "daybook_reminders", "media_tombstones"] {
            try expect(try upgraded.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]).count == 1, "v1 upgrade installs \(table)")
        }
        try expect(try upgraded.query("SELECT id FROM life_suppression")[0]["id"]?.string == "v1 sentinel", "upgrade retains v1 data")
        try expect(try upgraded.query("SELECT value FROM extension_sentinel")[0]["value"]?.string == "extension data", "upgrade retains extension tables")
        try upgraded.execute("PRAGMA user_version=999"); try failure { _ = try db(root) }
    }
    static func routingAndSharedDomains(_ root: URL) throws {
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["VoiceNotes", "PhotoMoments", "DaybookReminders"] {
            let actual = documents.appendingPathComponent(name, isDirectory: true)
            try expect(DaybookDatabase.metadataURL(forRoot: actual.appendingPathComponent("../" + name)) == DaybookDatabase.applicationURL, "standardized actual app root shares application database")
            let arbitrary = root.appendingPathComponent(name, isDirectory: true)
            try expect(DaybookDatabase.metadataURL(forRoot: arbitrary) == arbitrary.appendingPathComponent("metadata.sqlite3"), "same-named arbitrary roots remain isolated")
        }
        let database = try db(root)
        let notes = try NoteRepository(root: root.appendingPathComponent("voice"), database: database)
        let photos = try PhotoRepository(root: root.appendingPathComponent("photo"), database: database)
        let reminders = try DaybookReminderRepository(root: root.appendingPathComponent("reminder"), database: database)
        let source = root.appendingPathComponent("source.m4a"); try Data([1]).write(to: source)
        let note = try notes.importRecording(id: UUID(), from: source, kind: .long, capturedAt: .now, duration: 1)
        let moment = try photos.save(caption: "shared", photos: [PhotoImport(jpegData: jpeg)])
        let item = reminder(); try reminders.replace(with: [item]); try notes.delete(id: note.id)
        try expect(photos.moments == [moment] && reminders.items == [item], "shared database mutations preserve other domains")
        try expect(try database.query("SELECT domain FROM storage_migrations").count == 3, "each metadata domain migrates independently")
    }
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-sqlite-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("voice")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let note = VoiceNote(id: UUID(), kind: .thought, capturedAt: Date(timeIntervalSinceReferenceDate: 12345), duration: 12)
        let oldBytes = try JSONEncoder().encode([note])
        let json = root.appendingPathComponent("notes.json")
        try oldBytes.write(to: json)
        let repository = try NoteRepository(root: root)
        try repository.update(id: note.id) { $0.title = "Edited after migration" }
        try expect(try Data(contentsOf: json) == oldBytes, "post-migration edits must not rewrite legacy JSON")
        try voice(temporary.appendingPathComponent("voice-full"))
        try rollbackCleanupOwnership(temporary.appendingPathComponent("rollback-ownership"))
        try unsafeVoiceMedia(temporary.appendingPathComponent("unsafe-voice"))
        try migrationRetry(temporary.appendingPathComponent("voice-retry"))
        try photos(temporary.appendingPathComponent("photos"))
        try reminders(temporary.appendingPathComponent("reminders"))
        try schema(temporary.appendingPathComponent("schema"))
        try routingAndSharedDomains(temporary.appendingPathComponent("shared"))
        print("MetadataSQLiteSmoke passed: migration, rollback, retry, lossless voice payload, stale instances, tombstones, photo attachments, reminder diffs, date indices and schema compatibility")
    }
}
