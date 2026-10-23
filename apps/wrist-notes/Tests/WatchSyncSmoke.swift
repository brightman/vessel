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
        let activating = PhoneWatchStatus(isPaired: true, pendingCount: 3)
        expect(activating.title == "检查中" && activating.compactLabel == "检查中", "installation state is unknown until Watch Connectivity activates")
        expect(activating.message == "同步服务正在准备，请稍后刷新状态。" && !activating.hasPairedWatch, "unactivated session must not claim a pairing state")
        expect(!PhoneWatchStatus.canRequestSyncRetry(isSupported: true, isActivated: false, hasPairingID: true, isPaired: true, isInstalled: true), "retry must wait for Watch Connectivity activation")
        expect(PhoneWatchStatus.canRequestSyncRetry(isSupported: true, isActivated: true, hasPairingID: true, isPaired: true, isInstalled: true), "retry is available after activation with the paired app installed")
        expect(PhoneWatchStatus(isPaired: false, isInstalled: true, isActivated: true, pendingCount: 3).compactLabel == "未配对", "unpaired overrides cached data")
        expect(PhoneWatchStatus(isPaired: true, isActivated: true, pendingCount: 3).compactLabel == "待安装 App", "missing app overrides cached queue after activation")
        let legacySnapshot = Data("{\"updatedAt\":1000,\"pendingIDs\":[]}".utf8)
        expect(WatchSyncSnapshot.decode([WatchSyncSnapshot.contextKey: legacySnapshot])?.failures == nil, "legacy snapshot remains readable")
        var status = PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true)
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

        let sessionID = UUID(), transferTime = Date(timeIntervalSinceReferenceDate: 2_000)
        let transferPending = WatchSessionSyncSnapshot.Pending(
            sessionID: sessionID, lastOrdinal: 5, end: nil, totalChunkCount: 6,
            phase: .transferring, transferringChunkOrdinal: 2, currentChunkFraction: 0.4
        )
        let transferSnapshot = WatchSessionSyncSnapshot(updatedAt: transferTime, pending: [transferPending])
        let encoded = try JSONEncoder().encode(transferSnapshot)
        let decoded = try JSONDecoder().decode(WatchSessionSyncSnapshot.self, from: encoded)
        expect(decoded.pending[0].currentChunkFraction == 0.4, "current file fraction round-trips")
        let oldV2JSON = Data("""
        {"updatedAt":2000,"pending":[{"sessionID":"\(sessionID.uuidString)","lastOrdinal":2,"end":null}]}
        """.utf8)
        let decodedOldV2 = try JSONDecoder().decode(WatchSessionSyncSnapshot.self, from: oldV2JSON)
        expect(decodedOldV2.pending[0].currentChunkFraction == nil, "old V2 snapshots remain readable")

        let counterpartID = "progress-test"
        for ordinal in 0..<2 {
            let receipt = RecordingChunkReceipt(
                sessionID: sessionID, chunkID: UUID(), ordinal: ordinal,
                sha256: String(repeating: ordinal == 0 ? "a" : "b", count: 64)
            )
            try store.recordSaved(.init(receipt: receipt, savedAt: transferTime), counterpartID: counterpartID)
        }
        try store.apply(transferSnapshot, counterpartID: counterpartID)
        let transferSummary = try store.readSessions(counterpartID: counterpartID)
        expect(transferSummary.sessionTransfers.count == 1, "pending long recording is listed")
        expect(transferSummary.sessionTransfers[0].receivedChunkCount == 2, "only durable phone receipts count as received")
        expect(transferSummary.sessionTransfers[0].totalChunkCount == 6 && !transferSummary.sessionTransfers[0].isComplete,
               "partial receipt count cannot imply complete save")
        for ordinal in 2..<6 {
            let receipt = RecordingChunkReceipt(
                sessionID: sessionID, chunkID: UUID(), ordinal: ordinal,
                sha256: String(repeating: "c", count: 64)
            )
            try store.recordSaved(.init(receipt: receipt, savedAt: transferTime.addingTimeInterval(Double(ordinal))), counterpartID: counterpartID)
        }
        let end = RecordingSessionEnd(sessionID: sessionID, finalOrdinal: 5,
                                      endedAt: transferTime, interrupted: false, revision: 0)
        try store.recordEnd(end, counterpartID: counterpartID)
        let completedPending = WatchSessionSyncSnapshot.Pending(
            sessionID: sessionID, lastOrdinal: 5, end: end, totalChunkCount: 6, phase: .waiting
        )
        try store.apply(.init(updatedAt: transferTime.addingTimeInterval(1), pending: [completedPending]), counterpartID: counterpartID)
        let completedSummary = try store.readSessions(counterpartID: counterpartID)
        expect(completedSummary.pendingCount == 0 && completedSummary.sessionTransfers[0].isComplete,
               "all durable chunks and matching end metadata confirm phone save")
        try store.apply(.init(updatedAt: transferTime.addingTimeInterval(2), pending: []), counterpartID: counterpartID)
        let afterWatchAck = try store.readSessions(counterpartID: counterpartID)
        expect(afterWatchAck.pendingCount == 0 && afterWatchAck.sessionTransfers.first?.isComplete == true,
               "most recent completed session remains visible after Watch receives its ACK")
        expect(WatchTransferPhase.queued.rawValue == "queued", "queued status has stable wire value")
        expect(WatchSessionSyncSnapshot.phase(outstandingCount: 0, transferringCount: 0) == .waiting,
               "no system job waits on Watch")
        expect(WatchSessionSyncSnapshot.phase(outstandingCount: 2, transferringCount: 0) == .queued,
               "queued jobs are not reported active")
        expect(WatchSessionSyncSnapshot.phase(outstandingCount: 2, transferringCount: 1) == .transferring,
               "active job takes precedence")
        expect(WatchSessionSyncSnapshot.validProgressFraction(0.4) == 0.4, "finite progress is retained")
        expect(WatchSessionSyncSnapshot.validProgressFraction(.nan) == nil, "indeterminate progress is omitted")
        expect(WatchSessionSyncSnapshot.validProgressFraction(1.1) == nil, "out-of-range progress is omitted")

        let binding = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: UUID(), nonce: UUID())
        let invalidProgress = WatchSessionSyncSnapshot(
            updatedAt: transferTime,
            pending: [.init(sessionID: sessionID, lastOrdinal: 5, end: nil, totalChunkCount: 6,
                            phase: .transferring, transferringChunkOrdinal: 2, currentChunkFraction: -0.1)]
        )
        let invalidContext = [WatchSessionSyncSnapshot.contextKey: try JSONEncoder().encode(
            RecordingWireEnvelope(binding: binding, payload: invalidProgress)
        )]
        expect(WatchSessionSyncSnapshot.decode(invalidContext, binding: binding) == nil,
               "invalid active-file progress is rejected from untrusted context")

        let queuedRow = PhoneWatchStatus.TransferRow(
            sessionID: sessionID, receivedChunkCount: 0, totalChunkCount: 6, phase: .queued,
            transferringChunkOrdinal: nil, currentChunkFraction: nil, reportedAt: transferTime, isComplete: false
        )
        expect(queuedRow.stageLabel == "系统排队中" && queuedRow.currentChunkLabel == nil,
               "queued files do not claim active progress")
        let activeRow = PhoneWatchStatus.TransferRow(
            sessionID: sessionID, receivedChunkCount: 2, totalChunkCount: 6, phase: .transferring,
            transferringChunkOrdinal: 2, currentChunkFraction: 0.4, reportedAt: transferTime, isComplete: false
        )
        expect(activeRow.stageLabel == "后台传输中", "active transfer has a distinct stage")
        expect(activeRow.segmentLabel == "iPhone 已收到 2/6 段", "durable receipts drive received count")
        expect(activeRow.currentChunkLabel == "分片 3 · 40%", "current file fraction is shown separately")
        let unknownTotalRow = PhoneWatchStatus.TransferRow(
            sessionID: sessionID, receivedChunkCount: 2, totalChunkCount: nil, phase: .waiting,
            transferringChunkOrdinal: nil, currentChunkFraction: nil, reportedAt: transferTime, isComplete: false
        )
        expect(unknownTotalRow.segmentLabel == "iPhone 已收到 2 段", "unknown total is not rendered as zero")
        let completeRow = PhoneWatchStatus.TransferRow(
            sessionID: afterWatchAck.sessionTransfers[0].sessionID,
            receivedChunkCount: afterWatchAck.sessionTransfers[0].receivedChunkCount,
            totalChunkCount: afterWatchAck.sessionTransfers[0].totalChunkCount,
            phase: afterWatchAck.sessionTransfers[0].phase,
            transferringChunkOrdinal: afterWatchAck.sessionTransfers[0].transferringChunkOrdinal,
            currentChunkFraction: afterWatchAck.sessionTransfers[0].currentChunkFraction,
            reportedAt: afterWatchAck.sessionTransfers[0].reportedAt,
            isComplete: afterWatchAck.sessionTransfers[0].isComplete
        )
        expect(completeRow.stageLabel == "iPhone 已完整保存", "complete means durable phone persistence")
        print("Watch pairing, sync persistence, failure evidence and retry policy passed")
    }
}
