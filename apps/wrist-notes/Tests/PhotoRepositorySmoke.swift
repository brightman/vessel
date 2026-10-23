import Foundation

@main
struct PhotoRepositorySmoke {
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd9])

    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("photo-smoke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try persistenceAndDeletion(base.appendingPathComponent("normal"))
        try rejectedInputLeavesNoFiles(base.appendingPathComponent("inputs"))
        try failedIndexCommitRollsBackImages(base.appendingPathComponent("rollback"))
        try failedDeletePreservesRecord(base.appendingPathComponent("delete-failure"))
        try unsafeIndexIsRejected(base.appendingPathComponent("unsafe"))
        try symlinkCannotEscapeRepository(base.appendingPathComponent("symlink"))
        print("PhotoRepositorySmoke passed: persistence, OCR status, reopen, deletion, input validation, import rollback, failed-delete preservation, path and symlink validation")
    }

    // Catches lost caption/OCR metadata, incorrect durable filenames and deletion of only the index.
    static func persistenceAndDeletion(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let moment = try store.save(caption: "Lunch receipt", capturedAt: date, photos: [
            PhotoImport(jpegData: jpeg, recognizedText: "Total 42"),
            PhotoImport(jpegData: jpeg, recognizedText: "", recognitionError: "Recognition unavailable")
        ])
        check(moment.caption == "Lunch receipt" && moment.capturedAt == date)
        check(moment.recognizedText == "Total 42")
        check(moment.searchableText.contains("Lunch receipt") && moment.searchableText.contains("Total 42"))
        let firstURL = try store.imageURL(for: moment.photos[0])
        check(try Data(contentsOf: firstURL) == jpeg)
        let reopened = try PhotoRepository(root: root)
        check(reopened.moments == [moment])
        check(reopened.moments[0].photos[1].recognitionError == "Recognition unavailable")
        try reopened.delete(id: moment.id)
        check(reopened.moments.isEmpty)
        check(try PhotoRepository(root: root).moments.isEmpty)
        check(!FileManager.default.fileExists(atPath: firstURL.path))
        try reopened.delete(id: moment.id)
    }

    // Catches accepting empty/oversized batches or partial data after a later invalid attachment.
    static func rejectedInputLeavesNoFiles(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        try expectFailure { _ = try store.save(caption: "", photos: []) }
        try expectFailure { _ = try store.save(caption: "", photos: Array(repeating: PhotoImport(jpegData: jpeg), count: 7)) }
        try expectFailure { _ = try store.save(caption: "", photos: [PhotoImport(jpegData: jpeg), PhotoImport(jpegData: Data())]) }
        try expectFailure { _ = try store.save(caption: "", photos: [PhotoImport(jpegData: Data([1, 2, 3, 4]))]) }
        check(store.moments.isEmpty)
        check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty)
        check(try PhotoRepository(root: root).moments.isEmpty)
    }

    // A real SQLite failure must leave the old record intact and remove newly written images.
    static func failedIndexCommitRollsBackImages(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        let original = try store.save(caption: "Keep me", photos: [PhotoImport(jpegData: jpeg)])
        let database = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try database.execute("CREATE TRIGGER fail_photo_insert BEFORE INSERT ON photo_attachments WHEN NEW.position=1 BEGIN SELECT RAISE(ABORT,'injected'); END")
        try expectFailure { _ = try store.save(caption: "Must roll back", photos: [PhotoImport(jpegData: jpeg), PhotoImport(jpegData: jpeg)]) }
        check(store.moments == [original])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path)
        check(files == [original.photos[0].filename])
        try database.execute("DROP TRIGGER fail_photo_insert")
        check(try PhotoRepository(root: root).moments == [original])
    }

    // Catches removing images before an index update has durably committed.
    static func failedDeletePreservesRecord(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        let original = try store.save(caption: "Keep me", photos: [PhotoImport(jpegData: jpeg)])
        let url = try store.imageURL(for: original.photos[0])
        let database = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try database.execute("CREATE TRIGGER fail_photo_delete BEFORE DELETE ON photo_moments BEGIN SELECT RAISE(ABORT,'injected'); END")
        try expectFailure { try store.delete(id: original.id) }
        check(store.moments == [original])
        check(try Data(contentsOf: url) == jpeg)
    }

    // Catches directory traversal supplied through stored metadata or a caller-created attachment.
    static func unsafeIndexIsRejected(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        let attachment = PhotoAttachment(id: UUID(), filename: "../../outside.jpg", recognizedText: "")
        try expectFailure { _ = try store.imageURL(for: attachment) }
        let invalid = PhotoMoment(id: UUID(), capturedAt: .now, caption: "", recognizedText: "", photos: [attachment])
        let legacyRoot = root.appendingPathComponent("invalid-legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode([invalid]).write(to: legacyRoot.appendingPathComponent("moments.json"))
        try expectFailure { _ = try PhotoRepository(root: legacyRoot) }
    }

    // A syntactically valid filename must not allow reading a symlink outside the local library.
    static func symlinkCannotEscapeRepository(_ root: URL) throws {
        let store = try PhotoRepository(root: root)
        let moment = try store.save(caption: "", photos: [PhotoImport(jpegData: jpeg)])
        let url = try store.imageURL(for: moment.photos[0])
        let outside = root.appendingPathComponent("outside.jpg")
        try jpeg.write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        try expectFailure { _ = try store.imageURL(for: moment.photos[0]) }
        try expectFailure { _ = try PhotoRepository(root: root) }
        check(try Data(contentsOf: outside) == jpeg)
    }

    static func check(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(value, "Photo repository invariant failed", file: file, line: line)
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "PhotoRepositorySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected failure but operation succeeded"])
    }
}
