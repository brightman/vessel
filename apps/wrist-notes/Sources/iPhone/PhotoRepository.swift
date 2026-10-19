import Foundation

final class PhotoRepository {
    private let root: URL
    private let imagesDirectory: URL
    private let indexURL: URL
    private let files = FileManager.default
    private(set) var moments: [PhotoMoment] = []

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        imagesDirectory = self.root.appendingPathComponent("Images", isDirectory: true)
        indexURL = self.root.appendingPathComponent("moments.json")
        try files.createDirectory(at: self.root, withIntermediateDirectories: true)
        try rejectSymlink(imagesDirectory)
        try files.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try rejectSymlink(indexURL)
        if files.fileExists(atPath: indexURL.path) {
            let decoded = try JSONDecoder().decode([PhotoMoment].self, from: Data(contentsOf: indexURL))
            var momentIDs = Set<UUID>()
            var attachmentIDs = Set<UUID>()
            for moment in decoded {
                guard momentIDs.insert(moment.id).inserted, (1...6).contains(moment.photos.count),
                      moment.capturedAt.timeIntervalSince1970.isFinite else { throw PhotoStorageError.invalidIndex }
                for photo in moment.photos {
                    guard attachmentIDs.insert(photo.id).inserted else { throw PhotoStorageError.invalidIndex }
                    _ = try validatedURL(for: photo)
                }
            }
            moments = decoded
        }
    }

    func imageURL(for attachment: PhotoAttachment) throws -> URL {
        let url = try validatedURL(for: attachment)
        guard files.fileExists(atPath: url.path) else { throw PhotoStorageError.missingImage }
        return url
    }

    @discardableResult
    func save(caption: String, capturedAt: Date = .now, photos: [PhotoImport]) throws -> PhotoMoment {
        guard (1...6).contains(photos.count), capturedAt.timeIntervalSince1970.isFinite else {
            throw PhotoStorageError.invalidInput
        }
        for photo in photos {
            guard photo.jpegData.count >= 4, photo.jpegData.count <= 20 * 1_024 * 1_024,
                  photo.jpegData.starts(with: [0xff, 0xd8, 0xff]),
                  photo.jpegData.suffix(2) == Data([0xff, 0xd9]) else { throw PhotoStorageError.invalidImage }
        }
        try rejectSymlink(imagesDirectory)
        let attachments = photos.map { photo in
            let id = UUID()
            return PhotoAttachment(id: id, filename: "\(id.uuidString).jpg", recognizedText: photo.recognizedText,
                                   recognitionError: photo.recognitionError)
        }
        let moment = PhotoMoment(id: UUID(), capturedAt: capturedAt,
                                 caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                 recognizedText: attachments.map(\.recognizedText).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                 photos: attachments)
        var created: [URL] = []
        do {
            for (attachment, photo) in zip(attachments, photos) {
                let destination = try validatedURL(for: attachment)
                guard !files.fileExists(atPath: destination.path) else { throw PhotoStorageError.invalidIndex }
                try photo.jpegData.write(to: destination, options: .atomic)
                created.append(destination)
            }
            let revised = moments + [moment]
            try persist(revised)
            moments = revised
            return moment
        } catch {
            for url in created { try? files.removeItem(at: url) }
            throw error
        }
    }

    func delete(id: UUID) throws {
        guard let moment = moments.first(where: { $0.id == id }) else { return }
        // Validate every path before changing the index, including missing files.
        let urls = try moment.photos.map { try validatedURL(for: $0) }
        let revised = moments.filter { $0.id != id }
        try persist(revised)
        moments = revised
        for url in urls where files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    private func validatedURL(for attachment: PhotoAttachment) throws -> URL {
        guard attachment.filename == "\(attachment.id.uuidString).jpg" else { throw PhotoStorageError.unsafePath }
        try rejectSymlink(imagesDirectory)
        let url = imagesDirectory.appendingPathComponent(attachment.filename)
        try rejectSymlink(url)
        if files.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw PhotoStorageError.unsafePath
            }
        }
        return url
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw PhotoStorageError.unsafePath
        }
    }

    private func persist(_ revised: [PhotoMoment]) throws {
        try rejectSymlink(indexURL)
        try JSONEncoder().encode(revised).write(to: indexURL, options: .atomic)
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
