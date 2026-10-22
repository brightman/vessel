import Foundation

@MainActor
private final class Harness {
    var recording = false
    var starts = 0
    var requests = 0
    var permission: WatchRecordingLauncher.Permission = .granted
    var time: TimeInterval = 100
    var errors: [WatchRecordingLauncher.Failure] = []
    var reply: (@MainActor (Bool) -> Void)?
    lazy var launcher = WatchRecordingLauncher(
        isRecording: { self.recording },
        permission: { self.permission },
        requestPermission: { callback in self.requests += 1; self.reply = callback },
        startRecording: { self.starts += 1; self.recording = true },
        reportFailure: { self.errors.append($0) },
        now: { self.time }
    )
    func answer(_ allowed: Bool) {
        permission = allowed ? .granted : .denied
        let callback = reply; reply = nil; callback?(allowed)
    }
}

@main
struct WatchRecordingLauncherSmoke {
    @MainActor static func main() {
        let url = URL(string: "wiselife-watch://record")!
        // A missing foreground start is the initial red case.
        let direct = Harness()
        precondition(direct.launcher.open(url, phase: .active), "recording URL must be handled")
        precondition(direct.starts == 1, "foreground complication must start one recording")
        _ = direct.launcher.open(url, phase: .active)
        precondition(direct.starts == 1 && direct.recording, "second tap must preserve current recording")

        let normal = Harness()
        normal.launcher.setPhase(.active)
        precondition(normal.starts == 0, "normal App launch must never start recording")
        for invalid in ["wiselife://record", "https://record", "wiselife-watch://stop", "wiselife-watch://record/extra", "wiselife-watch://record?stop=1", "wiselife-watch://record#stop", "wiselife-watch://user@record", "wiselife-watch://record:80"] {
            precondition(!normal.launcher.open(URL(string: invalid)!, phase: .active), "unexpected URL must not record: \(invalid)")
        }
        precondition(normal.starts == 0 && normal.requests == 0)

        let cold = Harness()
        _ = cold.launcher.open(url, phase: .background)
        precondition(cold.starts == 0, "cold launch waits for the foreground")
        cold.launcher.setPhase(.active)
        cold.launcher.setPhase(.inactive)
        cold.launcher.setPhase(.active)
        precondition(cold.starts == 1, "phase changes cannot replay an already consumed URL")
        cold.recording = false
        cold.launcher.setPhase(.active)
        precondition(cold.starts == 1, "return after stopping cannot restart recording")

        let permission = Harness(); permission.permission = .undetermined
        _ = permission.launcher.open(url, phase: .active)
        _ = permission.launcher.open(url, phase: .active)
        precondition(permission.requests == 1 && permission.starts == 0, "only one microphone request")
        permission.launcher.setPhase(.inactive)
        permission.time += 60 // People may take time to read the permission prompt.
        permission.answer(true)
        precondition(permission.starts == 0, "grant while inactive must not start the microphone")
        permission.launcher.setPhase(.active)
        precondition(permission.starts == 1 && permission.errors.isEmpty)

        let denied = Harness(); denied.permission = .undetermined
        _ = denied.launcher.open(url, phase: .active)
        denied.answer(false)
        denied.launcher.setPhase(.active)
        precondition(denied.starts == 0 && denied.errors == [.microphoneDenied])
        let alreadyDenied = Harness(); alreadyDenied.permission = .denied
        _ = alreadyDenied.launcher.open(url, phase: .active)
        precondition(alreadyDenied.requests == 0 && alreadyDenied.errors == [.microphoneDenied])

        let left = Harness(); left.permission = .undetermined
        _ = left.launcher.open(url, phase: .active)
        left.launcher.setPhase(.background)
        left.answer(true)
        left.launcher.setPhase(.active)
        precondition(left.starts == 0 && left.errors.isEmpty, "grant after leaving must not resume old intent")
        _ = left.launcher.open(url, phase: .active)
        precondition(left.starts == 1, "fresh deliberate tap can start after a cancelled request")

        let expired = Harness()
        _ = expired.launcher.open(url, phase: .inactive)
        expired.time += 11
        expired.launcher.setPhase(.active)
        precondition(expired.starts == 0 && expired.errors == [.requestExpired], "late activation cannot silently record")

        let grantedButLate = Harness(); grantedButLate.permission = .undetermined
        _ = grantedButLate.launcher.open(url, phase: .active)
        grantedButLate.launcher.setPhase(.inactive)
        grantedButLate.answer(true)
        grantedButLate.time += 11
        grantedButLate.launcher.setPhase(.active)
        precondition(grantedButLate.starts == 0 && grantedButLate.errors == [.requestExpired])

        let otherStart = Harness(); otherStart.permission = .undetermined
        _ = otherStart.launcher.open(url, phase: .active)
        otherStart.recording = true
        otherStart.answer(true)
        precondition(otherStart.starts == 0 && otherStart.recording, "another entry owns its existing session")

        let fresh = Harness(); fresh.permission = .undetermined
        _ = fresh.launcher.open(url, phase: .active)
        fresh.launcher.setPhase(.background)
        _ = fresh.launcher.open(url, phase: .active)
        fresh.answer(true)
        precondition(fresh.starts == 1 && fresh.requests == 1, "new explicit request survives old permission completion")
        print("Watch recording launcher: 12 lifecycle, permission and routing scenarios passed")
    }
}
