import Foundation

actor GateTrace {
    var active = 0, maximum = 0
    var order: [Int] = []
    func enter(_ id: Int) { active += 1; maximum = max(maximum,active); order.append(id) }
    func leave() { active -= 1 }
    func snapshot() -> (Int,Int,[Int]) { (active,maximum,order) }
}
actor GateLatch {
    var open = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}
@main struct AudioInferenceGateSmoke {
    static func main() async throws {
        let gate = LocalAudioInferenceGate(), trace = GateTrace(), latch = GateLatch()
        let first = Task { try await gate.withPermit { await trace.enter(1); await latch.wait(); await trace.leave(); return 1 } }
        while await trace.snapshot().2.isEmpty { await Task.yield() }
        let attempted = GateLatch()
        let cancelled = Task {
            await attempted.release()
            return try await gate.withPermit { await trace.enter(99); await trace.leave(); return 99 }
        }
        await attempted.wait()
        // Keep permit 1 held while the other task reaches the gate's suspended acquire.
        try await Task.sleep(for:.milliseconds(10))
        // The first permit remains held. Cancel waiting work, then allow further jobs to finish.
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancelled waiter ran") } catch is CancellationError { }
        let second = Task { try await gate.withPermit { await trace.enter(2); await trace.leave(); return 2 } }
        await latch.release()
        _ = try await first.value; _ = try await second.value
        // Exercise cancellation races before queueing, during waiting, and on permit transfer.
        for _ in 0..<100 {
            let job = Task { try await gate.withPermit { try Task.checkCancellation(); return 0 } }
            job.cancel(); _ = try? await job.value
            let value = try await gate.withPermit { 7 }
            precondition(value == 7,"cancellation leaked permit")
        }
        let snapshot = await trace.snapshot()
        precondition(snapshot.0 == 0 && snapshot.1 == 1 && snapshot.2 == [1,2],"heavy work overlapped or cancelled job ran")
        print("Inference gate: passed (serial work, cancelled waiters, 100 cancellation/transfer races, permit reuse)")
    }
}
