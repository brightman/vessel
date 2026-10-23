import XCTest
import UIKit
@testable import WiseNote

@MainActor final class DesktopSyncIntegrationTests: XCTestCase {
    func testPhoneModelPairsSyncsAndReceivesSummaryOverPinnedTLS() async throws {
        let codeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("desktop-test-pairing.txt")
        guard FileManager.default.fileExists(atPath: codeURL.path) else { throw XCTSkip("Run desktop/scripts/test_ios.sh to start the Mac TLS fixture.") }
        let code = try String(contentsOf: codeURL, encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try DaybookDatabase(url: root.appendingPathComponent("phone.sqlite3"))
        let repository = try NoteRepository(root: root.appendingPathComponent("notes"), database: db)
        let source = root.appendingPathComponent("fixture.m4a"); try Data([1, 2, 3]).write(to: source)
        let id = UUID()
        _ = try repository.importRecording(id: id, from: source, kind: .long, capturedAt: .now, duration: 5)
        try repository.update(id: id) {
            $0.applyTranscription(.init(text: "模拟器与 Mac 的文本同步测试。", segments: [.init(start: 0, end: 5, text: "模拟器与 Mac 的文本同步测试。", speakerID: "speaker-1")]))
            $0.title = "端到端测试"; $0.titleManuallyEdited = true; $0.transcriptionState = .ready; $0.diarizationState = .ready
        }
        let suite = "DesktopSyncTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let notes = NotesModel(repository: repository, settings: settings, connectWatch: false)
        let sync = PhoneDesktopSyncModel(notes: notes, defaults: defaults, databaseURL: db.url, keychainService: suite)
        addTeardownBlock {
            try? SyncKeychain(service: suite).remove("peer")
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: codeURL)
        }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        sync.pair(code)
        try await wait("pair", sync: sync) { sync.peerName != nil && !sync.isSyncing }
        sync.syncNow()
        try await wait("upload", sync: sync) { !sync.isSyncing && sync.lastSynced != nil }
        sync.syncNow()
        try await wait("summary", sync: sync) { sync.summaries["legacyNote:" + id.uuidString] != nil && !sync.isSyncing }
        XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertEqual(sync.summaries["legacyNote:" + id.uuidString]?.model, "iOS transport fixture")
        XCTAssertNotNil(sync.summaries["legacyNote:" + id.uuidString]?.references.first?.start)
        let unpaired = await sync.unpair()
        XCTAssertTrue(unpaired, sync.message ?? "Unpair failed")
        XCTAssertNil(sync.peerName)
        XCTAssertTrue(sync.summaries.isEmpty)
    }
    private func wait(_ stage: String, sync: PhoneDesktopSyncModel, _ predicate: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(25)
        while !predicate() {
            guard Date.now < deadline else { XCTFail("Desktop sync \(stage) timeout: \(sync.message ?? "no status")"); throw DesktopSyncError.timeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
