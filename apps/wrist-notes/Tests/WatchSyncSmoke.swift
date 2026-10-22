import Foundation

@main struct WatchSyncSmoke {
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite3")
        let db = try DaybookDatabase(url: url)
        let store = try WatchSyncStore(database: db)
        let a = UUID(), b = UUID(), time = Date(timeIntervalSinceReferenceDate: 1000)
        expect(PhoneWatchStatus(isSupported: false, isPaired: true, isInstalled: true, pendingCount: 3).compactLabel == "Watch 不可用", "unsupported overrides cached data")
        expect(PhoneWatchStatus(isPaired: false, isInstalled: true, pendingCount: 3).compactLabel == "未配对", "unpaired overrides cached data")
        expect(PhoneWatchStatus(isPaired: true, pendingCount: 3).compactLabel == "待安装 App", "missing app overrides cached queue")
        let legacySnapshot = Data("{\"updatedAt\":1000,\"pendingIDs\":[]}".utf8)
        expect(WatchSyncSnapshot.decode([WatchSyncSnapshot.contextKey: legacySnapshot])?.failures == nil, "legacy snapshot remains readable")
        var status = PhoneWatchStatus(isPaired: true, isInstalled: true)
        expect(status.title == "已配对" && status.compactLabel == "已配对", "unknown is paired, not zero or disconnected")
        status.pendingCount = 0
        expect(status.compactLabel == "已配对", "empty queue without success time falls back to paired")
        expect(try store.read(pairingID: "A").pendingCount == nil, "no snapshot must remain unknown")
        try store.apply(.init(updatedAt: time, pendingIDs: [a, b, a]), pairingID: "A")
        var summary = try store.read(pairingID: "A")
        expect(summary.pendingCount == 2, "pending IDs are deduplicated")
        status.pendingCount = summary.pendingCount
        expect(status.title == "已配对 · 待同步 2 条", "pending count has priority")
        expect(status.compactLabel == "待同步2条", "home header uses compact queue text")
        try store.recordSaved(a, at: time.addingTimeInterval(10), pairingID: "A")
        try store.recordSaved(a, at: time.addingTimeInterval(50), pairingID: "A")
        summary = try store.read(pairingID: "A")
        expect(summary.pendingCount == 1 && summary.lastSyncedAt == time.addingTimeInterval(10), "duplicate acknowledgement must not move success time")
        // Delayed snapshot still lists an already-saved item.
        try store.apply(.init(updatedAt: time.addingTimeInterval(5), pendingIDs: [a, b]), pairingID: "A")
        expect(try store.read(pairingID: "A").pendingCount == 1, "late snapshot cannot resurrect saved work")
        try store.apply(.init(updatedAt: time.addingTimeInterval(-5), pendingIDs: []), pairingID: "A")
        expect(try store.read(pairingID: "A").pendingCount == 1, "out of order snapshot ignored")
        try store.recordSaved(b, at: time.addingTimeInterval(20), pairingID: "A")
        let reopened = try WatchSyncStore(database: DaybookDatabase(url: url))
        summary = try reopened.read(pairingID: "A")
        expect(summary.pendingCount == 0 && summary.lastSyncedAt == time.addingTimeInterval(20), "survives relaunch")
        expect(try reopened.read(pairingID: "B").lastSyncedAt == nil, "new paired Watch cannot inherit old Watch history")
        status.pendingCount = summary.pendingCount; status.lastSyncedAt = summary.lastSyncedAt
        expect(status.title.hasPrefix("已配对 · 最近同步 "), "confirmed success uses actual save time")
        let today = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!
        status.lastSyncedAt = today
        expect(status.compactLabel == "最近同步14:30", "home header uses compact 24-hour time")
        let asleep = status.title; status.isReachable = true
        expect(status.title == asleep, "wrist state cannot affect title")
        status.isPaired = false
        expect(status.title == "未配对 Apple Watch", "unpaired hides previous sync history")
        try db.execute("CREATE TRIGGER reject_sync_receipt BEFORE INSERT ON watch_sync_receipts BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        do { try store.recordSaved(UUID(), at: time.addingTimeInterval(100), pairingID: "A"); fatalError("write must fail") } catch {}
        expect(try store.read(pairingID: "A").lastSyncedAt == time.addingTimeInterval(20), "failed persistence cannot advance success time")
        // Genuine issues must be visible in details without inventing a new homepage state.
        var failureStatus = PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, pendingCount: 2)
        failureStatus.transferFailureCount = 1
        failureStatus.missingFileCount = 1
        failureStatus.phoneSaveFailed = true
        expect(failureStatus.compactLabel == "待同步2条" && failureStatus.issueMessages.count == 3, "detail errors must not replace compact queue state")
        expect(failureStatus.canRetrySync, "background retry cannot depend on wrist reachability")
        failureStatus.isInstalled = false
        expect(!failureStatus.canRetrySync && failureStatus.issueMessages.isEmpty, "missing app hides stale errors and disables retry")
        let retry = WatchSyncRetryRequest(id: UUID(), requestedAt: time)
        expect(retry.shouldHandle(lastHandledID: nil, now: time), "new retry must run")
        expect(!retry.shouldHandle(lastHandledID: retry.id, now: time), "same request must not retry twice")
        expect(!retry.shouldHandle(lastHandledID: nil, now: time.addingTimeInterval(86_401)), "stale context must not replay after relaunch")
        expect(!retry.shouldHandle(lastHandledID: nil, now: time.addingTimeInterval(-301)), "future timestamp is not a valid retry")
        let context = try WatchSyncRetryRequest.preparingContext(["locationEnabled": true], lastHandledID: nil, now: time)
        let firstRequest = WatchSyncRetryRequest.decode(context)!
        expect(context["locationEnabled"] as? Bool == true, "retry must preserve unrelated settings")
        let duplicate = try WatchSyncRetryRequest.preparingContext(context, lastHandledID: nil, now: time.addingTimeInterval(2))
        expect(WatchSyncRetryRequest.decode(duplicate)?.id == firstRequest.id, "repeated taps reuse the outstanding request")
        let next = try WatchSyncRetryRequest.preparingContext(context, lastHandledID: firstRequest.id, now: time.addingTimeInterval(3))
        expect(WatchSyncRetryRequest.decode(next)?.id != firstRequest.id, "a handled request can be retried again")
        let issueID = UUID()
        try store.apply(.init(updatedAt: time.addingTimeInterval(100), pendingIDs: [a, issueID], failures: [.init(id: a, reason: .transferFailed), .init(id: issueID, reason: .fileMissing)]), pairingID: "A")
        summary = try store.read(pairingID: "A")
        expect(summary.transferFailureCount == 0 && summary.missingFileCount == 1, "saved recordings cannot retain late failures")
        let restoredIssues = try WatchSyncStore(database: DaybookDatabase(url: url)).read(pairingID: "A")
        expect(restoredIssues.missingFileCount == 1, "failure evidence survives relaunch")
        try store.apply(.init(updatedAt: time.addingTimeInterval(101), pendingIDs: []), pairingID: "A")
        expect(try store.read(pairingID: "A").missingFileCount == 0, "removed recording clears its issue")
        print("Watch pairing, sync persistence, failure evidence and retry policy passed")
    }
}
