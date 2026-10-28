import Foundation

/// Confined to the coordinator actor. Cache entries are tied to immutable file metadata and validated again after hashing.
final class AudioSourceDiscovery {
    let root: URL
    private var db: DaybookDatabase?
    private var processing: AudioProcessingRepository?
    private var sessions: RecordingSessionRepository?
    private struct CachedFile { let stamp: String; let descriptor: String?; let info: RecordingAudioFileInfo }
    private var files: [URL:CachedFile] = [:]
    private(set) var unavailableSources: [AudioSourceID] = []
    init(root: URL) { self.root = root }
    func open() throws -> AudioProcessingRepository {
        // A delayed callback may never recreate a deleted/missing root or database.
        guard FileManager.default.fileExists(atPath:root.path), FileManager.default.fileExists(atPath:DaybookDatabase.metadataURL(forRoot:root).path) else { throw AudioProcessingError.deletedSource }
        if let processing { return processing }
        let db = try DaybookDatabase(url:DaybookDatabase.metadataURL(forRoot:root))
        self.db = db
        let processing = AudioProcessingRepository(database:db)
        self.processing = processing
        return processing
    }
    private func stamp(_ url: URL) throws -> String {
        try RecordingAudioFile.requireSafePath(url)
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw AudioProcessingError.invalidInput }
        let identity = [.systemNumber,.systemFileNumber,.size].map { String(describing:attributes[$0]) }.joined(separator:"|")
        let times = [.modificationDate,.creationDate].map { key in
            (attributes[key] as? Date).map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "missing"
        }.joined(separator:"|")
        return identity + "|" + times
    }
    private func inspect(_ url: URL, descriptor: RecordingChunkDescriptor? = nil) throws -> RecordingAudioFileInfo {
        let before = try stamp(url), key = descriptor.map(AudioStableID.make)
        if let cached = files[url], cached.stamp == before, cached.descriptor == key { return cached.info }
        let info = try descriptor.map { try RecordingAudioFile.validate($0,at:url) } ?? RecordingAudioFile.inspect(url)
        guard try stamp(url) == before else { throw AudioProcessingError.invalidInput }
        files[url] = CachedFile(stamp:before,descriptor:key,info:info)
        return info
    }
    func sources(explicit: [AudioSourceID]) throws -> [AudioSourceSnapshot] {
        let processing = try open()
        guard let db else { throw AudioProcessingError.invalidInput }
        let known = Set(try processing.sources().map(\.id)), requested = Set(explicit)
        var result: [AudioSourceSnapshot] = []
        unavailableSources = []
        // Only persisted note rows are read. Do not reopen NoteRepository/recover orphaned files from a queue callback.
        var groupedNotes: [UUID:[VoiceNote]] = [:]
        for row in try db.query("SELECT payload FROM voice_notes ORDER BY id") {
            let note = try DaybookDatabase.decode(VoiceNote.self,row["payload"])
            if let groupID = note.recordingGroupID {
                groupedNotes[groupID, default: []].append(note)
                continue
            }
            let id = AudioSourceID(kind:.legacyNote,id:note.id)
            let forced = requested.contains(id) || known.contains(id)
            guard forced || (note.kind == .long && note.transcriptionState != .ready && note.transcript.isEmpty) else { continue }
            do {
                let url = root.appendingPathComponent("Audio",isDirectory:true).appendingPathComponent(note.audioFilename)
                let info = try inspect(url)
                if !forced && !AudioLegacyRouting.requiresDurableProcessing(kind:note.kind,duration:note.duration,measuredDuration:Double(info.frameCount)/info.sampleRate) { continue }
                let range = try AudioSourceRange(range:.init(chunkID:note.id,url:url,startFrame:0,endFrame:info.frameCount,sampleRate:info.sampleRate),contentHash:info.sha256)
                result.append(try .init(id:id,capturedAt:note.capturedAt,title:note.title,origin:note.origin.map(AudioSourceOrigin.init),location:note.location,ranges:[range],complete:true))
            } catch { unavailableSources.append(id) }
        }
        // A logical long recording is a virtual, ordered set of ordinary files.
        // Wait for ordinal zero so the first durable note remains a stable source key.
        for (groupID, members) in groupedNotes {
            guard let first = members.first(where: { $0.recordingGroupOrdinal == 0 }) else { continue }
            let id = AudioSourceID(kind:.legacyNote,id:first.id)
            do {
                var ranges: [AudioSourceRange] = []
                for note in members.sorted(by: {
                    let left = $0.recordingGroupOrdinal ?? Int.max
                    let right = $1.recordingGroupOrdinal ?? Int.max
                    return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
                }) {
                    let url = root.appendingPathComponent("Audio",isDirectory:true).appendingPathComponent(note.audioFilename)
                    let info = try inspect(url)
                    let offset = note.recordingGroupOffset ?? ranges.last.map(\.end) ?? 0
                    let range = try AudioSourceRange(range:.init(chunkID:note.id,url:url,startFrame:0,endFrame:info.frameCount,
                        sampleRate:info.sampleRate,sessionStartOffset:offset),contentHash:info.sha256)
                    ranges.append(range)
                }
                result.append(try .init(id:id,recordingGroupID:groupID,capturedAt:first.capturedAt,title:"长录音",
                    origin:first.origin.map(AudioSourceOrigin.init),location:first.location,ranges:ranges,complete:true))
            } catch { unavailableSources.append(id) }
        }
        let repository: RecordingSessionRepository
        if let sessions { repository = sessions }
        else {
            repository = try RecordingSessionRepository(root:root.appendingPathComponent("RecordingSessions",isDirectory:true),database:db)
            sessions = repository
        }
        var offset = 0
        while true {
            // Paginate identities before decoding: one corrupt historical descriptor must
            // not discard valid notes already discovered or block the next session/page.
            let page = try db.query("SELECT id FROM recording_sessions ORDER BY id LIMIT 200 OFFSET ?", [.integer(Int64(offset))])
            for row in page {
                guard let text = row["id"]?.string, let sessionID = UUID(uuidString: text) else { continue }
                do {
                    guard let session = try repository.session(id: sessionID) else { continue }
                    let chunks = try repository.chunks(sessionID:session.id), hashes = Dictionary(uniqueKeysWithValues:chunks.map { ($0.id,$0.sha256) })
                    let ranges = try repository.sourceRanges(sessionID:session.id,validateFile:{ [self] chunk,url in _ = try inspect(url,descriptor:chunk) }).map { range in
                        try AudioSourceRange(range:range,contentHash:hashes[range.chunkID] ?? "")
                    }
                    result.append(try .init(id:.init(kind:.session,id:session.id),capturedAt:session.startedAt ?? Date(timeIntervalSinceReferenceDate:0),title:"完整录音",origin:session.origin.map(AudioSourceOrigin.init),location:session.location,ranges:ranges,complete:session.syncComplete))
                } catch { unavailableSources.append(.init(kind:.session,id:sessionID)) }
            }
            offset += page.count
            if page.count < 200 { break }
        }
        return result
    }
}
