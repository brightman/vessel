import Foundation
import Darwin

struct RecordingSessionInterval: Equatable {
    let start: Date
    let end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct RecordingSessionSummary: Identifiable {
    let id: UUID
    let startedAt: Date?
    let timeZoneIdentifier: String?
    let origin: RecordingOrigin?
    let location: CaptureLocation?
    let endedAt: Date?
    let endRevision: Int?
    let finalOrdinal: Int?
    let interrupted: Bool
    let savedCount: Int
    let expectedCount: Int?
    let recordedDuration: TimeInterval
    let syncComplete: Bool
    let recordedIntervals: [RecordingSessionInterval]
    let legacyNoteID: UUID?
}

struct RecordingSessionGap: Equatable {
    let kind: String
    let firstOrdinal: Int?
    let lastOrdinal: Int?
    let startOffset: Double?
    let endOffset: Double?
}

/// Synchronous disk/SQLite repository. Call imports, recovery and sourceRanges on a worker.
/// BEGIN IMMEDIATE serializes publication, identity checks and deletion across connections.
/// Callers must not wrap these operations in an outer DaybookDatabase.transaction; this repository owns the COMMIT boundary.
/// V1 notes remain in voice_notes; this repository never converts or rewrites them.
final class RecordingSessionRepository {
    enum RepositoryError: Error, Equatable {
        case conflict, deletedSession, invalidPairing, invalidStorage
    }
    enum ImportStep: Equatable { case publish, commit, reclaim }
    /// Injectable storage boundary; failures before commit propagate, reclamation is retryable.
    var importStep: ((ImportStep) throws -> Void)?
    private(set) var recoveryIssues: [String] = []
    private let root: URL
    private let audioDirectory: URL
    private let importsDirectory: URL
    private let db: DaybookDatabase
    private let files = FileManager.default
    private let lock = NSRecursiveLock()
    private struct Journal: Codable {
        let descriptor: RecordingChunkDescriptor
        let pairingID: String
    }

    init(root: URL, database: DaybookDatabase) throws {
        self.root = root
        self.db = database
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        importsDirectory = root.appendingPathComponent("Imports", isDirectory: true)
        try prepareDirectories()
        try recover()
    }

    /// Caller owns the persistent receiver inbox. Its source is never removed here.
    /// One private retry copy per chunk/hash survives publication or SQL failure.
    func importChunk(_ incoming: RecordingChunkDescriptor, from source: URL, pairingID: String) throws -> RecordingChunkReceipt {
        lock.lock(); defer { lock.unlock() }
        try incoming.validate()
        try validatePairing(pairingID)
        let chunk = normalized(incoming)
        try RecordingAudioFile.requireSafePath(source)
        _ = try RecordingAudioFile.validate(chunk, at: source)
        let receipt = try db.transaction {
            try requireLive(chunk.sessionID)
            if let existing = try existingChunk(id: chunk.id) {
                guard existing == chunk else { throw RepositoryError.conflict }
                _ = try RecordingAudioFile.validate(existing, at: audioURL(existing))
                try saveReceipt(chunk, pairingID: pairingID)
                return receiptFor(chunk)
            }
            try checkIdentityAndTimeline(chunk)
            let folder = journalFolder(chunk)
            try RecordingAudioFile.requireSafePath(folder)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try synchronizeDirectory(importsDirectory)
            #if os(iOS)
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
            #endif
            let manifest = folder.appendingPathComponent("manifest.json")
            let staged = folder.appendingPathComponent("audio.m4a")
            if files.fileExists(atPath: manifest.path) {
                let prior = try readJournal(manifest)
                guard normalized(prior.descriptor) == chunk else { throw RepositoryError.conflict }
            }
            try writeJournal(Journal(descriptor: chunk, pairingID: pairingID), to: manifest)
            try RecordingAudioFile.requireSafePath(staged)
            if files.fileExists(atPath: staged.path) {
                // A truncated interrupted copy is derived; retain the original source and
                // replace only this uncommitted staging artifact after validating source.
                if (try? RecordingAudioFile.validate(chunk, at: staged)) == nil { try files.removeItem(at: staged) }
            }
            if !files.fileExists(atPath: staged.path) { try files.copyItem(at: source, to: staged) }
            _ = try RecordingAudioFile.validate(chunk, at: staged)
            try synchronize(staged)
            let destination = audioURL(chunk)
            try RecordingAudioFile.requireSafePath(destination)
            try importStep?(.publish)
            if files.fileExists(atPath: destination.path) {
                // Adopt only bytes matching the retained descriptor; never overwrite finals.
                _ = try RecordingAudioFile.validate(chunk, at: destination)
            } else {
                // Same-volume rename publishes a complete file atomically; a process
                // death cannot leave a truncated final that blocks every later retry.
                try files.moveItem(at: staged, to: destination)
                try synchronizeDirectory(audioDirectory)
                try synchronizeDirectory(folder)
            }
            _ = try RecordingAudioFile.validate(chunk, at: destination)
            try establishSession(chunk)
            try db.execute("INSERT INTO recording_chunks(id,session_id,ordinal,filename,captured_at,session_start_offset,frame_count,sample_rate,byte_count,sha256,payload) VALUES (?,?,?,?,?,?,?,?,?,?,?)", try chunkValues(chunk))
            try saveReceipt(chunk, pairingID: pairingID)
            try rebuildGaps(chunk.sessionID)
            guard try existingChunk(id: chunk.id) == chunk else { throw RepositoryError.invalidStorage }
            try importStep?(.commit)
            return receiptFor(chunk)
        }
        // This point is reached only after SQLite COMMIT. Cleanup cannot revoke a receipt.
        try? reclaimJournal(chunk)
        return receipt
    }

    /// Compatibility entry point for local callers without a transport pairing context.
    func applyEnd(_ end: RecordingSessionEnd) throws { try applyEnd(end, pairingID: "local") }

    func applyEnd(_ end: RecordingSessionEnd, pairingID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try end.validate(); try validatePairing(pairingID)
        try db.transaction {
            try requireLive(end.sessionID)
            if let old = try storedEnd(sessionID: end.sessionID) {
                guard end.revision >= old.revision else { throw RepositoryError.conflict }
                if end.revision == old.revision, end != old { throw RepositoryError.conflict }
            }
            let maximum = try db.query("SELECT MAX(ordinal) AS maximum FROM recording_chunks WHERE session_id=?", [.text(end.sessionID.uuidString)]).first?["maximum"]
            if case let .integer(value) = maximum {
                guard let final = end.finalOrdinal, value <= Int64(final) else { throw RepositoryError.conflict }
            }
            try ensureSession(end.sessionID)
            try db.execute("UPDATE recording_sessions SET ended_at=?, interrupted=?, final_ordinal=?, end_revision=?, end_payload=? WHERE id=?", [.real(end.endedAt.timeIntervalSinceReferenceDate), .integer(end.interrupted ? 1 : 0), end.finalOrdinal.map { .integer(Int64($0)) } ?? .null, .integer(Int64(end.revision)), try DaybookDatabase.json(end), .text(end.sessionID.uuidString)])
            // A new pairing gets an independent receipt. Retries keep its first save time.
            if let old = try db.query("SELECT revision,payload FROM recording_end_receipts WHERE pairing_id=? AND session_id=?", [.text(pairingID), .text(end.sessionID.uuidString)]).first,
               try old.requiredInt("revision") == end.revision {
                guard try DaybookDatabase.decode(RecordingSessionEnd.self, old["payload"]) == end else { throw RepositoryError.conflict }
            } else {
                try db.execute("INSERT INTO recording_end_receipts(pairing_id,session_id,revision,payload,saved_at) VALUES (?,?,?,?,?) ON CONFLICT(pairing_id,session_id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload,saved_at=excluded.saved_at", [.text(pairingID), .text(end.sessionID.uuidString), .integer(Int64(end.revision)), try DaybookDatabase.json(end), .real(Date.now.timeIntervalSinceReferenceDate)])
            }
            try rebuildGaps(end.sessionID)
        }
    }

    func storedEnd(sessionID: UUID) throws -> RecordingSessionEnd? {
        guard let row = try db.query("SELECT id,ended_at,interrupted,final_ordinal,end_revision,end_payload FROM recording_sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              row["end_revision"] != .null else { return nil }
        let end = try DaybookDatabase.decode(RecordingSessionEnd.self, row["end_payload"])
        guard end.sessionID == sessionID,
              row["ended_at"] == .real(end.endedAt.timeIntervalSinceReferenceDate),
              row["interrupted"] == .integer(end.interrupted ? 1 : 0),
              row["end_revision"] == .integer(Int64(end.revision)),
              row["final_ordinal"] == (end.finalOrdinal.map { .integer(Int64($0)) } ?? .null) else { throw RepositoryError.invalidStorage }
        return end
    }

    func receiptSavedAt(chunkID: UUID, pairingID: String) throws -> Date? {
        guard let row = try db.query("SELECT saved_at FROM recording_receipts WHERE chunk_id=? AND pairing_id=?", [.text(chunkID.uuidString), .text(pairingID)]).first else { return nil }
        return Date(timeIntervalSinceReferenceDate: try row.requiredDouble("saved_at"))
    }

    /// Independently committed observations may arrive before audio or after the end marker.
    /// Returning successfully proves COMMIT; a tombstone prevents delayed resurrection.
    func importLocationSample(_ sample: RecordingLocationSample, pairingID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try sample.validate(); try validatePairing(pairingID)
        try db.transaction {
            try requireLive(sample.sessionID)
            if let row = try db.query("SELECT payload FROM recording_location_samples WHERE id=?", [.text(sample.id.uuidString)]).first {
                guard try DaybookDatabase.decode(RecordingLocationSample.self, row["payload"]) == sample else { throw RepositoryError.conflict }
                return
            }
            try ensureSession(sample.sessionID)
            try db.execute("INSERT INTO recording_location_samples(id,session_id,session_offset,requested_at,payload) VALUES (?,?,?,?,?)", [
                .text(sample.id.uuidString), .text(sample.sessionID.uuidString), .real(sample.sessionOffset),
                .real(sample.requestedAt.timeIntervalSinceReferenceDate), try DaybookDatabase.json(sample)])
        }
    }

    func locationSamples(sessionID: UUID) throws -> [RecordingLocationSample] {
        try db.query("SELECT s.id,s.session_id,s.session_offset,s.requested_at,s.payload,a.payload AS address FROM recording_location_samples s LEFT JOIN recording_location_addresses a ON a.sample_id=s.id WHERE s.session_id=? ORDER BY s.session_offset,s.requested_at,s.id", [.text(sessionID.uuidString)]).map { row in
            let sample = try DaybookDatabase.decode(RecordingLocationSample.self, row["payload"])
            guard sample.sessionID == sessionID, row["id"] == .text(sample.id.uuidString),
                  row["session_offset"] == .real(sample.sessionOffset),
                  row["requested_at"] == .real(sample.requestedAt.timeIntervalSinceReferenceDate) else { throw RepositoryError.invalidStorage }
            guard let address = try? DaybookDatabase.decode(CaptureAddress.self, row["address"]) else { return sample }
            var point = sample.location; point.address = address
            return RecordingLocationSample(id: sample.id, sessionID: sample.sessionID, sessionOffset: sample.sessionOffset,
                requestedAt: sample.requestedAt, location: point, sourceDevice: sample.sourceDevice)
        }
    }

    /// Cache is independently derived. Compare original capture identity inside the write transaction.
    @discardableResult func applyLocationAddress(_ address: CaptureAddress, sampleID: UUID, matching point: CaptureLocation) throws -> Bool {
        try db.transaction {
            guard let row = try db.query("SELECT payload FROM recording_location_samples WHERE id=?", [.text(sampleID.uuidString)]).first else { return false }
            let sample = try DaybookDatabase.decode(RecordingLocationSample.self, row["payload"])
            try requireLive(sample.sessionID)
            guard sample.location.matchesCapture(point) else { return false }
            try db.execute("INSERT INTO recording_location_addresses(sample_id,payload) VALUES (?,?) ON CONFLICT(sample_id) DO UPDATE SET payload=excluded.payload", [
                .text(sampleID.uuidString), try DaybookDatabase.json(address)])
            return true
        }
    }

    /// Metadata only; limits are bounded and no audio is read or hashed.
    func sessions(limit: Int = 50, offset: Int = 0) throws -> [RecordingSessionSummary] {
        try summaries(whereSQL: "", values: [], limit: limit, offset: offset)
    }

    /// Actual captured intervals overlap the requested day, including sessions begun earlier.
    func sessions(overlapping start: Date, end: Date, limit: Int = 50, offset: Int = 0) throws -> [RecordingSessionSummary] {
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite, start < end else { throw RepositoryError.invalidStorage }
        return try summaries(whereSQL: "WHERE EXISTS (SELECT 1 FROM recording_chunks c WHERE c.session_id=s.id AND c.captured_at < ? AND c.captured_at + CAST(c.frame_count AS REAL)/c.sample_rate > ?)", values: [.real(end.timeIntervalSinceReferenceDate), .real(start.timeIntervalSinceReferenceDate)], limit: limit, offset: offset)
    }

    func session(id: UUID) throws -> RecordingSessionSummary? {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM recording_sessions WHERE id=?", [.text(id.uuidString)]).first else { return nil }
            return try summary(row)
        }
    }

    func chunks(sessionID: UUID) throws -> [RecordingChunkDescriptor] {
        try db.query("SELECT * FROM recording_chunks WHERE session_id=? ORDER BY ordinal", [.text(sessionID.uuidString)]).map(decodeChunk)
    }

    func gaps(sessionID: UUID) throws -> [RecordingSessionGap] {
        try db.query("SELECT * FROM recording_gaps WHERE session_id=? ORDER BY COALESCE(first_ordinal,0),COALESCE(start_offset,0)", [.text(sessionID.uuidString)]).map {
            .init(kind: try $0.requiredString("kind"), firstOrdinal: try optionalInt($0, "first_ordinal"), lastOrdinal: try optionalInt($0, "last_ordinal"), startOffset: $0["start_offset"]?.double, endOffset: $0["end_offset"]?.double)
        }
    }

    /// Worker-only expensive inspection, serialized against deletion/publication.
    func sourceRanges(sessionID: UUID, validateFile: ((RecordingChunkDescriptor, URL) throws -> Void)? = nil) throws -> [RecordingSourceRange] {
        try db.transaction {
            try requireLive(sessionID)
            var previous: RecordingChunkDescriptor?
            return try chunks(sessionID: sessionID).map { chunk in
                let url = audioURL(chunk)
                if let validateFile { try validateFile(chunk,url) }
                else { _ = try RecordingAudioFile.validate(chunk, at: url) }
                let missing = chunk.ordinal != (previous.map { $0.ordinal + 1 } ?? 0)
                let gap = chunk.sessionStartOffset > (previous.map { $0.sessionStartOffset + $0.duration } ?? 0) + 0.5 / chunk.sampleRate
                let range = RecordingSourceRange(chunkID: chunk.id, url: url, startFrame: 0, endFrame: chunk.frameCount, sampleRate: chunk.sampleRate, sessionStartOffset: chunk.sessionStartOffset, discontinuityBefore: missing ? "missingChunks" : (gap ? "captureGap" : nil))
                try range.validate(); previous = chunk
                return range
            }
        }
    }

    func deleteSession(_ sessionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO recording_session_tombstones(session_id,deleted_at) VALUES (?,?)", [.text(sessionID.uuidString), .real(Date.now.timeIntervalSinceReferenceDate)])
            var filenames = Set(try chunks(sessionID: sessionID).map(\.audioFilename))
            // A published file may precede a rolled-back INSERT. Its retained journal
            // still supplies exact cleanup identity even when no SQL chunk row exists.
            for folder in try files.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: nil) {
                if let journal = try? readJournal(folder.appendingPathComponent("manifest.json")), journal.descriptor.sessionID == sessionID,
                   folder.lastPathComponent == journalFolder(normalized(journal.descriptor)).lastPathComponent {
                    filenames.insert(journal.descriptor.audioFilename)
                }
            }
            for filename in filenames {
                try db.execute("INSERT OR IGNORE INTO recording_file_cleanup(filename,session_id,deleted_at) VALUES (?,?,?)", [.text(filename), .text(sessionID.uuidString), .real(Date.now.timeIntervalSinceReferenceDate)])
            }
            try db.execute("DELETE FROM recording_sessions WHERE id=?", [.text(sessionID.uuidString)])
        }
        try? cleanupDeletedFiles()
    }

    func cleanupPending(sessionID: UUID) throws -> Bool {
        try !db.query("SELECT filename FROM recording_file_cleanup WHERE session_id=? LIMIT 1", [.text(sessionID.uuidString)]).isEmpty
    }

    func pendingCleanupSessionIDs(limit: Int = 200) throws -> [UUID] {
        try db.query("SELECT DISTINCT session_id FROM recording_file_cleanup ORDER BY session_id LIMIT ?", [.integer(Int64(min(200, max(1, limit))))]).map {
            guard let id = UUID(uuidString: try $0.requiredString("session_id")) else { throw RepositoryError.invalidStorage }
            return id
        }
    }

    /// Each valid independent journal is replayed; damaged bytes remain available for diagnosis.
    func recover() throws {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectories()
        recoveryIssues = []
        try? cleanupDeletedFiles()
        for folder in try files.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: nil) {
            do {
                try RecordingAudioFile.requireSafePath(folder)
                let journal = try readJournal(folder.appendingPathComponent("manifest.json"))
                guard folder.lastPathComponent == journalFolder(normalized(journal.descriptor)).lastPathComponent else { throw RepositoryError.invalidStorage }
                if try isDeleted(journal.descriptor.sessionID) {
                    try deleteSession(journal.descriptor.sessionID)
                    continue
                }
                let stage = folder.appendingPathComponent("audio.m4a")
                let source = (try? RecordingAudioFile.validate(journal.descriptor, at: stage)) != nil ? stage : audioURL(journal.descriptor)
                _ = try importChunk(journal.descriptor, from: source, pairingID: journal.pairingID)
            } catch {
                // Bounded diagnostics contain only internal folder identifiers, never metadata.
                if recoveryIssues.count < 100 { recoveryIssues.append(folder.lastPathComponent) }
            }
        }
    }

    private func summaries(whereSQL: String, values: [DaybookDatabase.Value], limit: Int, offset: Int) throws -> [RecordingSessionSummary] {
        try db.transaction {
            try db.query("SELECT s.* FROM recording_sessions s \(whereSQL) ORDER BY COALESCE(s.started_at,s.ended_at,s.created_at) DESC,s.id LIMIT ? OFFSET ?", values + [.integer(Int64(min(200, max(1, limit)))), .integer(Int64(max(0, offset)))]).map(summary)
        }
    }

    private func summary(_ row: DaybookDatabase.Row) throws -> RecordingSessionSummary {
        guard let id = UUID(uuidString: try row.requiredString("id")) else { throw RepositoryError.invalidStorage }
        let list = try chunks(sessionID: id)
        let end = try storedEnd(sessionID: id)
        let expected = end.map { $0.finalOrdinal.map { $0 + 1 } ?? 0 }
        let complete = expected.map { count in list.count == count && (count == 0 || (list.first?.ordinal == 0 && list.last?.ordinal == count - 1)) } ?? false
        let intervals = list.map { RecordingSessionInterval(start: $0.capturedAt, end: $0.capturedAt.addingTimeInterval($0.duration)) }
        return .init(id: id, startedAt: row["started_at"]?.double.map { Date(timeIntervalSinceReferenceDate: $0) }, timeZoneIdentifier: row["time_zone_identifier"]?.string, origin: list.first?.origin, location: list.first?.location, endedAt: end?.endedAt, endRevision: end?.revision, finalOrdinal: end?.finalOrdinal, interrupted: end?.interrupted ?? false, savedCount: list.count, expectedCount: expected, recordedDuration: list.reduce(0) { $0 + $1.duration }, syncComplete: complete, recordedIntervals: intervals, legacyNoteID: row["legacy_note_id"]?.string.flatMap(UUID.init(uuidString:)))
    }

    private func checkIdentityAndTimeline(_ chunk: RecordingChunkDescriptor) throws {
        // Publication intents are durable identities too: a failed SQL transaction
        // must not let a new ID silently take over the same pending ordinal.
        for folder in try files.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: nil) {
            guard let journal = try? readJournal(folder.appendingPathComponent("manifest.json")),
                  folder.lastPathComponent == journalFolder(normalized(journal.descriptor)).lastPathComponent else { continue }
            let pending = normalized(journal.descriptor)
            if pending.id == chunk.id || (pending.sessionID == chunk.sessionID && pending.ordinal == chunk.ordinal) {
                guard pending == chunk else { throw RepositoryError.conflict }
            }
        }
        guard try db.query("SELECT id FROM recording_chunks WHERE session_id=? AND ordinal=?", [.text(chunk.sessionID.uuidString), .integer(Int64(chunk.ordinal))]).isEmpty else { throw RepositoryError.conflict }
        if let end = try storedEnd(sessionID: chunk.sessionID) {
            guard let final = end.finalOrdinal, chunk.ordinal <= final else { throw RepositoryError.conflict }
        }
        if let row = try db.query("SELECT started_at,time_zone_identifier,origin FROM recording_sessions WHERE id=?", [.text(chunk.sessionID.uuidString)]).first, row["started_at"] != .null {
            let origin = try DaybookDatabase.decode(RecordingOrigin.self, row["origin"])
            guard row["started_at"] == .real(chunk.sessionStartedAt.timeIntervalSinceReferenceDate), row["time_zone_identifier"] == .text(chunk.timeZoneIdentifier),
                  origin.device == chunk.origin.device, origin.deviceID == chunk.origin.deviceID,
                  origin.recordingTimeIsEstimated == chunk.origin.recordingTimeIsEstimated else { throw RepositoryError.conflict }
        }
        for (relation, order) in [("<", "DESC"), (">", "ASC")] {
            if let row = try db.query("SELECT * FROM recording_chunks WHERE session_id=? AND ordinal \(relation) ? ORDER BY ordinal \(order) LIMIT 1", [.text(chunk.sessionID.uuidString), .integer(Int64(chunk.ordinal))]).first {
                let neighbor = try decodeChunk(row)
                let left = relation == "<" ? neighbor : chunk, right = relation == "<" ? chunk : neighbor
                guard left.sessionStartOffset + left.duration <= right.sessionStartOffset else { throw RepositoryError.conflict }
            }
        }
    }

    private func establishSession(_ chunk: RecordingChunkDescriptor) throws {
        try ensureSession(chunk.sessionID)
        try db.execute("UPDATE recording_sessions SET started_at=?,time_zone_identifier=?,origin=? WHERE id=? AND started_at IS NULL", [.real(chunk.sessionStartedAt.timeIntervalSinceReferenceDate), .text(chunk.timeZoneIdentifier), try DaybookDatabase.json(chunk.origin), .text(chunk.sessionID.uuidString)])
    }
    private func ensureSession(_ id: UUID) throws {
        try db.execute("INSERT OR IGNORE INTO recording_sessions(id,created_at) VALUES (?,?)", [.text(id.uuidString), .real(Date.now.timeIntervalSinceReferenceDate)])
    }
    private func saveReceipt(_ chunk: RecordingChunkDescriptor, pairingID: String) throws {
        if let row = try db.query("SELECT session_id,ordinal,sha256 FROM recording_receipts WHERE pairing_id=? AND chunk_id=?", [.text(pairingID), .text(chunk.id.uuidString)]).first {
            guard row["session_id"] == .text(chunk.sessionID.uuidString), row["ordinal"] == .integer(Int64(chunk.ordinal)), row["sha256"] == .text(chunk.sha256) else { throw RepositoryError.invalidStorage }
        } else {
            try db.execute("INSERT INTO recording_receipts(pairing_id,chunk_id,session_id,ordinal,sha256,saved_at) VALUES (?,?,?,?,?,?)", [.text(pairingID), .text(chunk.id.uuidString), .text(chunk.sessionID.uuidString), .integer(Int64(chunk.ordinal)), .text(chunk.sha256), .real(Date.now.timeIntervalSinceReferenceDate)])
        }
    }
    private func receiptFor(_ chunk: RecordingChunkDescriptor) -> RecordingChunkReceipt {
        .init(sessionID: chunk.sessionID, chunkID: chunk.id, ordinal: chunk.ordinal, sha256: chunk.sha256)
    }
    private func existingChunk(id: UUID) throws -> RecordingChunkDescriptor? {
        try db.query("SELECT * FROM recording_chunks WHERE id=?", [.text(id.uuidString)]).first.map(decodeChunk)
    }
    private func chunkValues(_ chunk: RecordingChunkDescriptor) throws -> [DaybookDatabase.Value] {
        [.text(chunk.id.uuidString), .text(chunk.sessionID.uuidString), .integer(Int64(chunk.ordinal)), .text(chunk.audioFilename), .real(chunk.capturedAt.timeIntervalSinceReferenceDate), .real(chunk.sessionStartOffset), .integer(chunk.frameCount), .real(chunk.sampleRate), .integer(chunk.byteCount), .text(chunk.sha256), try DaybookDatabase.json(chunk)]
    }
    private func decodeChunk(_ row: DaybookDatabase.Row) throws -> RecordingChunkDescriptor {
        let chunk = try DaybookDatabase.decode(RecordingChunkDescriptor.self, row["payload"])
        let values = try chunkValues(chunk)
        for (i, column) in ["id", "session_id", "ordinal", "filename", "captured_at", "session_start_offset", "frame_count", "sample_rate", "byte_count", "sha256"].enumerated() {
            guard row[column] == values[i] else { throw RepositoryError.invalidStorage }
        }
        return chunk
    }
    private func normalized(_ c: RecordingChunkDescriptor) -> RecordingChunkDescriptor {
        .init(id: c.id, sessionID: c.sessionID, ordinal: c.ordinal, sessionStartedAt: c.sessionStartedAt, capturedAt: c.capturedAt, timeZoneIdentifier: c.timeZoneIdentifier, sessionStartOffset: c.sessionStartOffset, frameCount: c.frameCount, sampleRate: c.sampleRate, byteCount: c.byteCount, sha256: c.sha256.lowercased(), origin: c.origin, location: c.location)
    }
    private func optionalInt(_ row: DaybookDatabase.Row, _ name: String) throws -> Int? {
        row[name] == .null ? nil : try row.requiredInt(name)
    }
    private func validatePairing(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1024 else { throw RepositoryError.invalidPairing }
    }
    private func isDeleted(_ id: UUID) throws -> Bool {
        try !db.query("SELECT session_id FROM recording_session_tombstones WHERE session_id=?", [.text(id.uuidString)]).isEmpty
    }
    private func requireLive(_ id: UUID) throws {
        if try isDeleted(id) { throw RepositoryError.deletedSession }
    }
    private func audioURL(_ chunk: RecordingChunkDescriptor) -> URL { audioDirectory.appendingPathComponent(chunk.audioFilename) }
    private func journalFolder(_ chunk: RecordingChunkDescriptor) -> URL { importsDirectory.appendingPathComponent("\(chunk.id.uuidString)_\(chunk.sha256.lowercased())", isDirectory: true) }
    private func prepareDirectories() throws {
        for folder in [root, audioDirectory, importsDirectory] {
            try RecordingAudioFile.requireSafePath(folder)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            #if os(iOS)
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
            #endif
            try synchronizeDirectory(folder)
            try synchronizeDirectory(folder.deletingLastPathComponent())
        }
    }
    private func readJournal(_ url: URL) throws -> Journal {
        try RecordingAudioFile.requireSafePath(url)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1024 else { throw RepositoryError.invalidStorage }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }
    private func writeJournal(_ journal: Journal, to url: URL) throws {
        try RecordingAudioFile.requireSafePath(url)
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 128 * 1024 else { throw RepositoryError.invalidStorage }
        try data.write(to: url, options: .atomic)
        try synchronize(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }
    private func synchronizeDirectory(_ url: URL) throws {
        try RecordingAudioFile.requireSafePath(url)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        #if os(iOS)
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private func reclaimJournal(_ chunk: RecordingChunkDescriptor) throws {
        try db.transaction {
            try importStep?(.reclaim)
            let folder = journalFolder(chunk)
            try RecordingAudioFile.requireSafePath(folder)
            if files.fileExists(atPath: folder.path) {
                try files.removeItem(at: folder)
                try synchronizeDirectory(importsDirectory)
            }
        }
    }
    private func cleanupDeletedFiles() throws {
        try db.transaction {
            try importStep?(.reclaim)
            for row in try db.query("SELECT * FROM recording_file_cleanup") {
                guard let id = UUID(uuidString: try row.requiredString("session_id")), try isDeleted(id) else { throw RepositoryError.invalidStorage }
                let filename = try row.requiredString("filename")
                // Validate both UUID prefix and numeric suffix without trusting a stored path.
                let prefix = id.uuidString + "_"
                guard filename.hasPrefix(prefix), filename.hasSuffix(".m4a"), let ordinal = Int(filename.dropFirst(prefix.count).dropLast(4)), (0...RecordingChunkProtocol.maximumOrdinal).contains(ordinal), filename == "\(prefix)\(String(format: "%04d", ordinal)).m4a" else { throw RepositoryError.invalidStorage }
                let url = audioDirectory.appendingPathComponent(filename)
                try RecordingAudioFile.requireSafePath(url)
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                try synchronizeDirectory(audioDirectory)
                try db.execute("DELETE FROM recording_file_cleanup WHERE filename=?", [.text(filename)])
            }
            for folder in try files.contentsOfDirectory(at: importsDirectory, includingPropertiesForKeys: nil) {
                if let journal = try? readJournal(folder.appendingPathComponent("manifest.json")),
                   folder.lastPathComponent == journalFolder(normalized(journal.descriptor)).lastPathComponent,
                   try isDeleted(journal.descriptor.sessionID) {
                    try RecordingAudioFile.requireSafePath(folder)
                    try files.removeItem(at: folder)
                    try synchronizeDirectory(importsDirectory)
                }
            }
        }
    }
    private func rebuildGaps(_ sessionID: UUID) throws {
        try db.execute("DELETE FROM recording_gaps WHERE session_id=?", [.text(sessionID.uuidString)])
        let list = try chunks(sessionID: sessionID)
        var expected = 0
        var previousEnd: Double = 0
        for chunk in list {
            if chunk.ordinal > expected { try insertGap(sessionID, key: "missing-\(expected)", kind: "missingChunks", first: expected, last: chunk.ordinal - 1) }
            if chunk.ordinal == expected && chunk.sessionStartOffset > previousEnd + 0.5 / chunk.sampleRate {
                try insertGap(sessionID, key: "offset-\(chunk.ordinal)", kind: "captureGap", start: previousEnd, end: chunk.sessionStartOffset)
            }
            expected = chunk.ordinal + 1
            previousEnd = chunk.sessionStartOffset + chunk.duration
        }
        if let final = try storedEnd(sessionID: sessionID)?.finalOrdinal, expected <= final {
            try insertGap(sessionID, key: "missing-\(expected)", kind: "missingChunks", first: expected, last: final)
        }
    }
    private func insertGap(_ id: UUID, key: String, kind: String, first: Int? = nil, last: Int? = nil, start: Double? = nil, end: Double? = nil) throws {
        try db.execute("INSERT INTO recording_gaps(session_id,gap_key,kind,first_ordinal,last_ordinal,start_offset,end_offset) VALUES (?,?,?,?,?,?,?)", [.text(id.uuidString), .text(key), .text(kind), first.map { .integer(Int64($0)) } ?? .null, last.map { .integer(Int64($0)) } ?? .null, start.map { .real($0) } ?? .null, end.map { .real($0) } ?? .null])
    }
}
