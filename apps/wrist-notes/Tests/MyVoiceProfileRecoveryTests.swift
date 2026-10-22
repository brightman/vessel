import XCTest
import UIKit
@testable import WiseLifeProfileVerification

@MainActor final class MyVoiceProfileRecoveryTests: XCTestCase {
    func testProtectedDataAndForegroundEventsRestoreEnrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceProfileStore(root: root)
        let vector = [Float](repeating: 0, count: 255) + [1]
        let original = try VoiceIdentityPolicy.makeProfile(embeddings: [vector, vector, vector], duration: 35)
        try store.save(original)
        let file = root.appendingPathComponent("profile.json")
        let bytes = try Data(contentsOf: file)
        for notification in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            try Data("unreadable fixture".utf8).write(to: file)
            let model = MyVoiceProfileModel(store: store)
            XCTAssertNotNil(model.storageError)
            XCTAssertFalse(model.label.contains("未登记"))
            try bytes.write(to: file)
            NotificationCenter.default.post(name: notification, object: nil)
            for _ in 0..<1_000 { if model.storageError == nil { break }; await Task.yield() }
            XCTAssertNil(model.storageError)
            XCTAssertEqual(model.profile, original)
        }
    }

    func testSuccessfulSaveSurvivesLeavingAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceProfileStore(root: root)
        let vector = [Float](repeating: 0, count: 255) + [1]
        let original = try VoiceIdentityPolicy.makeProfile(embeddings: [vector, vector, vector], duration: 35)
        let model = MyVoiceProfileModel(store: store, enroll: { _ in original })
        let saved = await model.saveRecording(url: root, duration: 35, confirmedSolo: true)
        XCTAssertTrue(saved)
        model.cancelEnrollment()
        XCTAssertEqual(MyVoiceProfileModel(store: VoiceProfileStore(root: root)).profile, original)
        // Simulator does not expose physical-device file protection attributes.
        XCTAssertEqual(try root.appendingPathComponent("profile.json").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
