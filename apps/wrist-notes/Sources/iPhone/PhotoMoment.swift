import Foundation

struct PhotoAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let recognizedText: String
    var recognitionError: String? = nil
    var capture: PhotoCaptureMetadata? = nil
}

struct PhotoMoment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let caption: String
    let recognizedText: String
    let photos: [PhotoAttachment]
    var importedAt: Date? = nil

    var captureDevice: String {
        let devices = Set(photos.map { $0.capture?.device ?? "设备未知" })
        return devices.count == 1 ? devices.first! : "多种设备"
    }

    var title: String {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "照片记录" : String(text.prefix(60))
    }

    var searchableText: String {
        [caption, recognizedText].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct PhotoImport: Sendable {
    let jpegData: Data
    var recognizedText: String = ""
    var recognitionError: String? = nil
    var capture: PhotoCaptureMetadata? = nil
}
