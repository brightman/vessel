import Foundation

final class PhotoRepository {
    private let imagesDirectory: URL
    private let db: DaybookDatabase
    private let files = FileManager.default
    private(set) var moments: [PhotoMoment] = []

    init(root: URL, database: DaybookDatabase? = nil) throws {
        let root = root.standardizedFileURL
        imagesDirectory = root.appendingPathComponent("Images", isDirectory: true)
        db = try database ?? DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try rejectSymlink(imagesDirectory)
        try files.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("moments.json")
        try db.migrate("photo_moments") {
            try rejectSymlink(indexURL)
            let decoded = files.fileExists(atPath: indexURL.path)
                ? try JSONDecoder().decode([PhotoMoment].self, from: Data(contentsOf: indexURL)) : []
            guard Set(decoded.map(\.id)).count == decoded.count,
                  Set(decoded.flatMap(\.photos).map(\.id)).count == decoded.flatMap(\.photos).count else { throw PhotoStorageError.invalidIndex }
            for moment in decoded { try insert(moment) }
            _ = try load()
        }
        moments = try db.transaction { try load() }
        cleanupTombstones()
    }

    func imageURL(for attachment: PhotoAttachment) throws -> URL {
        let url = try validatedURL(for: attachment)
        guard files.fileExists(atPath: url.path) else { throw PhotoStorageError.missingImage }
        return url
    }

    @discardableResult
    func save(caption: String, capturedAt: Date = .now, photos: [PhotoImport]) throws -> PhotoMoment {
        guard (1...6).contains(photos.count), capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw PhotoStorageError.invalidInput }
        for photo in photos {
            guard photo.capture?.capturedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw PhotoStorageError.invalidInput }
            guard photo.jpegData.count >= 4, photo.jpegData.count <= 20 * 1_024 * 1_024,
                  photo.jpegData.starts(with: [0xff, 0xd8, 0xff]),
                  photo.jpegData.suffix(2) == Data([0xff, 0xd9]) else { throw PhotoStorageError.invalidImage }
        }
        let attachments = photos.map { photo in
            let id = UUID()
            return PhotoAttachment(id: id, filename: "\(id.uuidString).jpg", recognizedText: photo.recognizedText, recognitionError: photo.recognitionError, capture: photo.capture)
        }
        // Keep each photo on its original day; the entire selection commits atomically.
        let groups = Dictionary(grouping: attachments) { Calendar.current.startOfDay(for: $0.capture?.capturedAt ?? capturedAt) }
        let newMoments = groups.values.map { group in
            PhotoMoment(id: UUID(), capturedAt: group.map { $0.capture?.capturedAt ?? capturedAt }.min() ?? capturedAt,
                caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                recognizedText: group.map(\.recognizedText).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                photos: group, importedAt: capturedAt)
        }.sorted { $0.capturedAt > $1.capturedAt }
        var created: [URL] = []
        let revised: [PhotoMoment]
        do {
            revised = try db.transaction {
                for (attachment, photo) in zip(attachments, photos) {
                    let destination = try validatedURL(for: attachment)
                    guard !files.fileExists(atPath: destination.path) else { throw PhotoStorageError.invalidIndex }
                    try photo.jpegData.write(to: destination, options: .atomic)
                    created.append(destination)
                }
                for moment in newMoments { try insert(moment) }
                return try load()
            }
        } catch {
            // Serialize cleanup with other connections and preserve any file already adopted
            // by committed metadata. Database/cleanup failures must not mask the save error.
            try? db.transaction {
                for url in created {
                    guard try db.query("SELECT id FROM photo_attachments WHERE filename=?", [.text(url.lastPathComponent)]).isEmpty else { continue }
                    try rejectSymlink(imagesDirectory)
                    try? files.removeItem(at: url)
                }
            }
            throw error
        }
        moments = revised
        return newMoments[0]
    }

    @discardableResult
    func setAddress(_ address: CaptureAddress, photoID: UUID, matching point: CaptureLocation) throws -> Bool {
        let result = try db.transaction {
            guard let row = try db.query("SELECT capture FROM photo_attachments WHERE id=?", [.text(photoID.uuidString)]).first,
                  row["capture"] != .null else { return (false, try load()) }
            var capture = try DaybookDatabase.decode(PhotoCaptureMetadata.self, row["capture"])
            guard capture.location?.matchesCapture(point) == true else { return (false, try load()) }
            capture.location?.address = address
            try db.execute("UPDATE photo_attachments SET capture=? WHERE id=?", [try DaybookDatabase.json(capture), .text(photoID.uuidString)])
            return (true, try load())
        }
        moments = result.1
        return result.0
    }

    func delete(id: UUID) throws {
        let revised = try db.transaction {
            if let moment = try load().first(where: { $0.id == id }) {
                for photo in moment.photos {
                    _ = try validatedURL(for: photo)
                    try db.execute("INSERT OR REPLACE INTO media_tombstones(kind,id,filename,deleted_at) VALUES ('photo',?,?,?)", [.text(photo.id.uuidString), .text(photo.filename), .real(Date.now.timeIntervalSinceReferenceDate)])
                }
                try db.execute("DELETE FROM photo_moments WHERE id=?", [.text(id.uuidString)])
            }
            return try load()
        }
        moments = revised
        cleanupTombstones()
    }

    private func insert(_ moment: PhotoMoment) throws {
        guard (1...6).contains(moment.photos.count), moment.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(moment.photos.map(\.id)).count == moment.photos.count else { throw PhotoStorageError.invalidIndex }
        for photo in moment.photos { _ = try validatedURL(for: photo) }
        try db.execute("INSERT INTO photo_moments(id,captured_at,caption,recognized_text,imported_at) VALUES (?,?,?,?,?)", [.text(moment.id.uuidString), .real(moment.capturedAt.timeIntervalSinceReferenceDate), .text(moment.caption), .text(moment.recognizedText), moment.importedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null])
        for (position, photo) in moment.photos.enumerated() {
            try db.execute("INSERT INTO photo_attachments(id,moment_id,position,filename,recognized_text,recognition_error,capture) VALUES (?,?,?,?,?,?,?)", [.text(photo.id.uuidString), .text(moment.id.uuidString), .integer(Int64(position)), .text(photo.filename), .text(photo.recognizedText), photo.recognitionError.map(DaybookDatabase.Value.text) ?? .null, try photo.capture.map { try DaybookDatabase.json($0) } ?? .null])
        }
    }
    private func load() throws -> [PhotoMoment] {
        try db.query("SELECT * FROM photo_moments ORDER BY captured_at,id").map { row in
            guard let id = UUID(uuidString: try row.requiredString("id")) else { throw PhotoStorageError.invalidIndex }
            let photos = try db.query("SELECT * FROM photo_attachments WHERE moment_id=? ORDER BY position", [.text(id.uuidString)]).enumerated().map { position, attachment in
                guard let id = UUID(uuidString: try attachment.requiredString("id")), try attachment.requiredInt("position") == position else { throw PhotoStorageError.invalidIndex }
                let error: String?
                switch attachment["recognition_error"] {
                case .null: error = nil
                case .text(let value): error = value
                default: throw PhotoStorageError.invalidIndex
                }
                let photo = PhotoAttachment(id: id, filename: try attachment.requiredString("filename"), recognizedText: try attachment.requiredString("recognized_text"), recognitionError: error, capture: attachment["capture"] == .null ? nil : try DaybookDatabase.decode(PhotoCaptureMetadata.self, attachment["capture"]))
                _ = try validatedURL(for: photo)
                return photo
            }
            guard (1...6).contains(photos.count) else { throw PhotoStorageError.invalidIndex }
            return PhotoMoment(id: id, capturedAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("captured_at")), caption: try row.requiredString("caption"), recognizedText: try row.requiredString("recognized_text"), photos: photos, importedAt: row["imported_at"]?.double.map { Date(timeIntervalSinceReferenceDate: $0) })
        }
    }
    private func cleanupTombstones() {
        try? db.transaction {
            for row in try db.query("SELECT id,filename FROM media_tombstones WHERE kind='photo'") {
                guard let id = UUID(uuidString: try row.requiredString("id")),
                      try db.query("SELECT id FROM photo_attachments WHERE id=?", [.text(id.uuidString)]).isEmpty else { continue }
                let attachment = PhotoAttachment(id: id, filename: try row.requiredString("filename"), recognizedText: "")
                if let url = try? validatedURL(for: attachment), files.fileExists(atPath: url.path) { try? files.removeItem(at: url) }
            }
        }
    }
    private func validatedURL(for attachment: PhotoAttachment) throws -> URL {
        guard attachment.filename == "\(attachment.id.uuidString).jpg" else { throw PhotoStorageError.unsafePath }
        try rejectSymlink(imagesDirectory)
        let url = imagesDirectory.appendingPathComponent(attachment.filename)
        try rejectSymlink(url)
        if files.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PhotoStorageError.unsafePath }
        }
        return url
    }
    private func rejectSymlink(_ url: URL) throws {
        if (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw PhotoStorageError.unsafePath }
    }
}

enum PhotoStorageError: LocalizedError {
    case invalidInput, invalidImage, invalidIndex, unsafePath, missingImage

    var errorDescription: String? {
        switch self {
        case .invalidInput: "请选择 1 至 6 张照片。"
        case .invalidImage: "照片数据无效或超过 20 MB，请重新选择。"
        case .invalidIndex: "本地照片记录无效，原始文件已保留。"
        case .unsafePath: "照片路径无效，无法访问该文件。"
        case .missingImage: "找不到本地照片文件。"
        }
    }
}
