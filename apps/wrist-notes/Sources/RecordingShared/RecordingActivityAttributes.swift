import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording, saved, failed
        }
        var phase: Phase
    }

    var sessionID: UUID
    var startedAt: Date
}
