import AVFAudio
import XCTest
@testable import WiseNote

@MainActor final class PhoneRecorderEnrollmentTests: XCTestCase {
    func testFinalizedFramesRecoverSixtySecondsDespiteLaggingTimer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960_000))
        buffer.frameLength = 960_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 960_000)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        XCTAssertEqual(PhoneRecorder.completedFileDuration(url: url, fallback: 29), 60, accuracy: 0.001)
    }

    func testUnreadableCompletedFilePreservesMeasuredDuration() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(PhoneRecorder.completedFileDuration(url: missing, fallback: 35), 35)
    }

    func testAlreadyCancelledStartNeverRequestsMicrophoneOrCreatesDraft() async {
        let recorder = PhoneRecorder()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await recorder.start(maximumDuration: 60, builtInMicrophoneOnly: true)
        }
        await task.value
        XCTAssertFalse(recorder.requestingPermission)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.draft)
        XCTAssertNil(recorder.errorMessage)
    }
}
