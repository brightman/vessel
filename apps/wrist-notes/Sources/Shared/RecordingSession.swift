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

/// Capture identity is supplied only by the local recorder. A missing end on a
/// receiving device does not establish that the Watch is currently recording.
struct RecordingSessionSyncPresentation: Equatable {
    enum Phase { case recording, awaitingEnd, syncing, complete }
    let savedChunkCount: Int
    let sealedChunkCount: Int
    let phase: Phase
    var isComplete: Bool { phase == .complete }

    init(sessionID: UUID, activeSessionID: UUID?, savedChunkCount: Int,
         sealedChunkCount: Int, hasEnd: Bool, syncComplete: Bool) {
        self.sealedChunkCount = max(0, sealedChunkCount)
        self.savedChunkCount = min(max(0, savedChunkCount), self.sealedChunkCount)
        if activeSessionID == sessionID { phase = .recording }
        else if !hasEnd { phase = .awaitingEnd }
        else if syncComplete { phase = .complete }
        else { phase = .syncing }
    }
}
