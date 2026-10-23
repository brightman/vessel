import Foundation

@main struct CaptureMetadataSmoke {
    static func main() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let point = CaptureLocation(latitude: 31.2, longitude: 121.5, accuracy: 15, measuredAt: date, source: .watchRecording)!
        precondition(CaptureLocation(latitude: 91, longitude: 0, source: .photoMetadata) == nil)
        precondition(CaptureLocation(latitude: .nan, longitude: 0, source: .photoMetadata) == nil)
        precondition(CaptureLocation(latitude: 0, longitude: 0, accuracy: -1, source: .photoMetadata) == nil)
        precondition(CaptureLocation.decodeTransfer(point.transferData) == point)
        precondition(CaptureLocation.decodeTransfer(Data("invalid".utf8)) == nil)
        precondition(point.isNearCapture(date))
        precondition(!point.isNearCapture(date.addingTimeInterval(120)))
        let pending = PendingRecording(id: UUID(), kind: .thought, capturedAt: date, duration: 2, location: point)
        let restoredPending = try JSONDecoder().decode(PendingRecording.self, from: JSONEncoder().encode(pending))
        precondition(restoredPending.location == point && !restoredPending.uploaded)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drafts = PhoneRecordingDraftStore(root: root.appendingPathComponent("drafts"))
        var draft = try drafts.prepare(id: UUID(), at: date)
        draft.location = point
        try drafts.persist(draft)
        let recoveredDraft = try drafts.load()[0]
        precondition(recoveredDraft.location == point)
        let audio = root.appendingPathComponent("source.m4a")
        try Data([1,2,3]).write(to: audio)
        let notes = try NoteRepository(root: root.appendingPathComponent("notes"))
        let id = UUID()
        _ = try notes.importRecording(id: id, from: audio, kind: .long, capturedAt: date, duration: 5,
            origin: RecordingOrigin(device: "Apple Watch", deviceID: "", fileName: "", recordingTimeIsEstimated: false), location: point)
        let reopened = try NoteRepository(root: root.appendingPathComponent("notes"))
        precondition(reopened.notes.first?.location == point)
        precondition(reopened.notes.first?.origin?.device == "Apple Watch")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.notes[0])) as! [String: Any]
        legacy.removeValue(forKey: "location")
        let oldNote = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(oldNote.location == nil)
        let photosRoot = root.appendingPathComponent("photos")
        let photos = try PhotoRepository(root: photosRoot)
        let jpeg = Data([0xff,0xd8,0xff,0xe0,0x00,0x02,0xff,0xd9])
        let metadata = PhotoCaptureMetadata(capturedAt: date, device: "iPhone 16 Pro", importMethod: .library, location: point)
        let moment = try photos.save(caption: "a", capturedAt: date.addingTimeInterval(600), photos: [PhotoImport(jpegData: jpeg, capture: metadata)])
        let restored = try PhotoRepository(root: photosRoot).moments[0]
        precondition(restored.capturedAt == date, "Use original capture date")
        precondition(restored.importedAt == date.addingTimeInterval(600))
        precondition(restored.photos[0].capture == metadata)
        try photos.delete(id: moment.id)
        let empty = try PhotoRepository(root: photosRoot)
        precondition(empty.moments.isEmpty)
        let mixedRoot = root.appendingPathComponent("mixed-days")
        let mixedStore = try PhotoRepository(root: mixedRoot)
        var nextDay = metadata
        nextDay.capturedAt = date.addingTimeInterval(86400)
        _ = try mixedStore.save(caption: "mixed", capturedAt: date.addingTimeInterval(172800), photos: [PhotoImport(jpegData: jpeg, capture: metadata), PhotoImport(jpegData: jpeg, capture: nextDay)])
        let grouped = try PhotoRepository(root: mixedRoot).moments
        precondition(grouped.count == 2 && grouped.allSatisfy { $0.photos.count == 1 }, "Batch photos belong to their original days")
        // Reconstruct v2 with real rows, then exercise the additive migration.
        let oldRoot = root.appendingPathComponent("old-photos")
        let oldStore = try PhotoRepository(root: oldRoot)
        let old = try oldStore.save(caption: "legacy", photos: [PhotoImport(jpegData: jpeg)])
        let oldDB = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: oldRoot))
        try oldDB.execute("ALTER TABLE photo_moments DROP COLUMN imported_at")
        try oldDB.execute("ALTER TABLE photo_attachments DROP COLUMN capture")
        try oldDB.execute("DROP TABLE reminder_apple_links")
        try oldDB.execute("PRAGMA user_version=2")
        let migrated = try PhotoRepository(root: oldRoot).moments[0]
        precondition(migrated.id == old.id && migrated.photos[0].capture == nil && migrated.importedAt == nil)
        print("Capture metadata: validation, transfer, legacy decode, SQLite reopen/delete passed")
    }
}
