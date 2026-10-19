import Foundation

/// A press has exactly one result, so releasing a thought can never trigger a tap.
struct RecordingButtonInteraction {
    enum Action: Equatable {
        case startLong, stopLong, startThought, saveThought, cancelThought, discardShortThought
    }
    private enum Phase { case idle, arming, longRecording, thought, moved }
    private var phase: Phase = .idle
    private var beganAt: TimeInterval = 0
    private var thoughtAt: TimeInterval = 0
    private(set) var cancelOnRelease = false
    var isActive: Bool { phase != .idle }
    var isArming: Bool { phase == .arming }
    var isThought: Bool { phase == .thought }
    static let holdDuration: TimeInterval = 0.45

    mutating func begin(at time: TimeInterval, isRecording: Bool) {
        guard !isActive else { return }
        beganAt = time
        cancelOnRelease = false
        phase = isRecording ? .longRecording : .arming
    }

    mutating func move(x: Double, y: Double) {
        if phase == .thought {
            cancelOnRelease = y < -35
        } else if phase == .arming || phase == .longRecording {
            if hypot(x, y) > 25 { phase = .moved }
        }
    }

    mutating func recognizeHold(at time: TimeInterval) -> Action? {
        guard phase == .arming, time - beganAt >= Self.holdDuration else { return nil }
        phase = .thought
        thoughtAt = time
        return .startThought
    }

    mutating func end(at time: TimeInterval) -> Action? {
        defer { self = Self() }
        switch phase {
        case .arming:
            return time - beganAt < Self.holdDuration ? .startLong : nil
        case .longRecording:
            return time - beganAt < Self.holdDuration ? .stopLong : nil
        case .thought:
            if cancelOnRelease { return .cancelThought }
            return time - thoughtAt < 0.3 ? .discardShortThought : .saveThought
        case .idle, .moved:
            return nil
        }
    }

    mutating func interrupt() -> Action? {
        defer { self = Self() }
        return phase == .thought ? .cancelThought : nil
    }
}
