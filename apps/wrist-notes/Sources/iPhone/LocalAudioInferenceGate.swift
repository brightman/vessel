import Foundation

/// One FIFO across ASR, VAD, diarization and enrollment, including injected service instances.
actor LocalAudioInferenceGate {
    static let shared = LocalAudioInferenceGate()
    private var running = false
    private var waiters: [(UUID,CheckedContinuation<Void,Error>)] = []

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        // Install release before checking post-acquisition cancellation (including a handoff race).
        defer { release() }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !running { running = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                waiters.append((id,continuation))
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at:index).1.resume(throwing:CancellationError())
    }
    private func release() {
        if waiters.isEmpty { running = false }
        else { waiters.removeFirst().1.resume() }
    }
}
