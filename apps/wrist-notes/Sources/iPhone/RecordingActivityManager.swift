import ActivityKit
import Foundation

@MainActor
final class RecordingActivityManager: RecordingActivityManaging {
    enum ActivityError: LocalizedError {
        case disabled
        case unavailable
        var errorDescription: String? {
            switch self {
            case .disabled:
                NSLocalizedString("请在系统设置中允许 WiseLife 的实时活动，然后重新开始录音。", comment: "Recording Live Activity error")
            case .unavailable:
                NSLocalizedString("暂时无法创建录音实时活动，请打开 WiseLife 后重试。", comment: "Recording Live Activity error")
            }
        }
    }

    var onDismiss: ((UUID) -> Void)?
    private var activities: [UUID: Activity<RecordingActivityAttributes>] = [:]
    private var observations: [UUID: Task<Void, Never>] = [:]
    func endObsoleteActivities() async {
        // A recorder cannot survive process termination. Remove its obsolete card
        // before publishing a card for a new recording.
        for activity in Activity<RecordingActivityAttributes>.activities {
            if activities[activity.attributes.sessionID] == nil {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func start(sessionID: UUID, startedAt: Date) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityError.disabled
        }
        guard activities[sessionID] == nil else { return }
        let activity: Activity<RecordingActivityAttributes>
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(sessionID: sessionID, startedAt: startedAt),
                content: ActivityContent(state: .init(phase: .recording), staleDate: nil),
                pushType: nil
            )
        } catch {
            throw ActivityError.unavailable
        }
        activities[sessionID] = activity
        observations[sessionID] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    guard let self, self.activities.removeValue(forKey: sessionID) != nil else { return }
                    self.observations.removeValue(forKey: sessionID)
                    self.onDismiss?(sessionID)
                    return
                }
            }
        }
    }

    func finish(sessionID: UUID, saved: Bool) async {
        // Remove and cancel before ending, so our own end is never a stop request.
        observations.removeValue(forKey: sessionID)?.cancel()
        guard let activity = activities.removeValue(forKey: sessionID) else { return }
        await activity.end(
            ActivityContent(state: .init(phase: saved ? .saved : .failed), staleDate: nil),
            dismissalPolicy: .immediate
        )
    }
}
