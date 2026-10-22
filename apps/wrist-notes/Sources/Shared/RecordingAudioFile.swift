import AVFAudio
import CryptoKit
import Foundation

struct RecordingAudioFileInfo {
    let sampleRate: Double
    /// Container/decoder frames, which can include bounded encoder tail padding.
    let frameCount: Int64
    let channelCount: Int
    let byteCount: Int64
    let sha256: String
    let formatID: AudioFormatID
}

enum RecordingAudioFile {
    enum ValidationError: Error { case unsafePath, invalidAudio, descriptorMismatch }

    /// Reject links in every existing path component (including a linked parent).
    static func requireSafePath(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw ValidationError.unsafePath }
        var cursor = url
        while cursor.path != "/" {
            cursor.removeAllCachedResourceValues()
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                // Darwin exposes its protected data volume through /var. Only this
                // fixed OS alias is accepted; application-controlled links are rejected.
                guard cursor.path == "/var", (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var")) == "private/var" else { throw ValidationError.unsafePath }
            }
            cursor.deleteLastPathComponent()
        }
    }

    static func inspect(_ url: URL) throws -> RecordingAudioFileInfo {
        try requireSafePath(url)
        var freshURL = url
        // Recovery may replace an uncommitted artifact at the same URL. URL's
        // resource cache must not supply the old truncated file's byte count.
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { throw ValidationError.invalidAudio }
        let audio = try AVAudioFile(forReading: url)
        let rate = audio.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, audio.length > 0 else { throw ValidationError.invalidAudio }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return .init(sampleRate: rate, frameCount: audio.length, channelCount: Int(audio.processingFormat.channelCount),
                     byteCount: Int64(bytes), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                     formatID: audio.fileFormat.streamDescription.pointee.mFormatID)
    }

    static func validate(_ descriptor: RecordingChunkDescriptor, at url: URL) throws -> RecordingAudioFileInfo {
        try descriptor.validate()
        let info = try inspect(url)
        // AAC-LC encodes 1024-frame packets. The m4a packet table normally trims
        // priming/tail; permit at most one final packet of untrimmed tail padding.
        // Effective capture frames always remain the descriptor's frameCount.
        guard info.formatID == kAudioFormatMPEG4AAC, info.sampleRate == 16_000, info.channelCount == 1,
              descriptor.sampleRate == info.sampleRate, info.frameCount >= descriptor.frameCount,
              info.frameCount - descriptor.frameCount < 1024,
              info.byteCount == descriptor.byteCount,
              info.sha256.caseInsensitiveCompare(descriptor.sha256) == .orderedSame else { throw ValidationError.descriptorMismatch }
        return info
    }
}
