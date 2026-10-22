import Foundation

/// Capture completion and file delivery are independent states.
enum RecordingSessionState: String, Codable {
    case recording, stopped, interrupted
}

enum RecordingChunkState: String, Codable {
    case sealed, pendingTransfer, acknowledged
}

enum RecordingSessionValidationError: Error, Equatable {
    case invalidField(String)
}

/// Frames use [startFrame, endFrame); offsets preserve real capture interruptions.
/// URLs are resolved locally by the repository, never received as wire metadata.
struct RecordingSourceRange: Equatable {
    let chunkID: UUID
    let url: URL
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    var sessionStartOffset: Double = 0
    var discontinuityBefore: String? = nil

    var duration: Double {
        let (frames, overflow) = endFrame.subtractingReportingOverflow(startFrame)
        return overflow ? .nan : Double(frames) / sampleRate
    }

    func validate() throws {
        guard startFrame >= 0, endFrame > startFrame else {
            throw RecordingSessionValidationError.invalidField("frameRange")
        }
        guard sampleRate.isFinite, sampleRate > 0, duration.isFinite, duration > 0 else {
            throw RecordingSessionValidationError.invalidField("sampleRate")
        }
        guard sessionStartOffset.isFinite, sessionStartOffset >= 0,
              (sessionStartOffset + duration).isFinite else {
            throw RecordingSessionValidationError.invalidField("sessionStartOffset")
        }
        guard url.isFileURL else { throw RecordingSessionValidationError.invalidField("url") }
    }
}
