import Foundation

private func expect(_ condition: Bool, _ message: String = "address contract") { precondition(condition, message) }

@main struct CaptureAddressPersistenceSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("data.sqlite3"))
        let point = CaptureLocation(latitude: 31.2345, longitude: 121.5432, measuredAt: .now, source: .watchRecording)!
        let address = CaptureAddress(text: "上海市浦东新区世纪大道 1 号", localeIdentifier: "zh-Hans")!
        precondition(CaptureAddress(text: " \n", localeIdentifier: "zh-Hans") == nil)
        let original = try JSONEncoder().encode(point)
        expect(try JSONDecoder().decode(CaptureLocation.self, from: original).address == nil)
        let notesRoot = root.appendingPathComponent("notes")
        let repository = try NoteRepository(root: notesRoot, database: db)
        let audio = root.appendingPathComponent("audio.m4a"); try Data([1,2]).write(to: audio)
        let note = try repository.importRecording(id: UUID(), from: audio, kind: .long, capturedAt: .now, duration: 12, location: point)
        try repository.update(id: note.id) { $0.transcript = "保留原文"; $0.summary = "保留总结" }
        expect(try repository.setAddress(address, noteID: note.id, matching: point))
        let reopened = try NoteRepository(root: notesRoot, database: db)
        precondition(reopened.notes[0].location?.address == address && reopened.notes[0].transcript == "保留原文" && reopened.notes[0].summary == "保留总结")
        precondition(reopened.notes[0].location?.displayTitle == "上海市浦东新区世纪大道 1 号")
        precondition(reopened.notes[0].location?.latitude == 31.2345)
        let wrong = CaptureLocation(latitude: 32, longitude: 121, source: .watchRecording)!
        expect(try !repository.setAddress(address, noteID: note.id, matching: wrong))
        try reopened.delete(id: note.id)
        expect(try !repository.setAddress(address, noteID: note.id, matching: point), "stale repository cannot resurrect a deleted note")
        expect(try db.query("SELECT * FROM voice_notes").isEmpty)

        let photosRoot = root.appendingPathComponent("photos")
        let photos = try PhotoRepository(root: photosRoot, database: db)
        let metadata = PhotoCaptureMetadata(capturedAt: .now, device: "iPhone", importMethod: .library, location: point)
        let moment = try photos.save(caption: "保留说明", photos: [PhotoImport(jpegData: Data([0xff,0xd8,0xff,0xd9]), recognizedText: "保留 OCR", capture: metadata)])
        let photoID = moment.photos[0].id
        expect(try photos.setAddress(address, photoID: photoID, matching: point))
        let saved = try PhotoRepository(root: photosRoot, database: db).moments[0]
        precondition(saved.photos[0].capture?.location?.address == address && saved.caption == "保留说明" && saved.photos[0].recognizedText == "保留 OCR")
        precondition(saved.importedAt == moment.importedAt && saved.capturedAt == moment.capturedAt)
        try db.execute("CREATE TRIGGER fail_address BEFORE UPDATE ON photo_attachments BEGIN SELECT RAISE(ABORT, 'test write failure'); END")
        do { _ = try photos.setAddress(CaptureAddress(text: "Other address", localeIdentifier: "en")!, photoID: photoID, matching: point); fatalError("failed write accepted") } catch {}
        precondition(photos.moments[0].photos[0].capture?.location?.address == address, "failed transaction cannot publish uncommitted address")
        try db.execute("DROP TRIGGER fail_address")
        try photos.delete(id: moment.id)
        expect(try !photos.setAddress(address, photoID: photoID, matching: point))
        expect(try db.query("SELECT * FROM photo_attachments").isEmpty)
        print("Capture addresses: SQLite persistence, original coordinate/text preservation, deleted/stale writes, photo rollback and legacy decoding passed")
    }
}
