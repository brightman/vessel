import Foundation
import AVFAudio
import UIKit
import XCTest
@testable import WiseLifeStorageVerification

@MainActor private final class LifecycleScheduler: DaybookReminderScheduling {
    var scheduled: [String: DaybookReminder] = [:]
    func authorization() async -> DaybookNotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> DaybookNotificationAuthorization { .authorized }
    func schedule(_ reminder: DaybookReminder) async throws { scheduled[reminder.notificationID] = reminder }
    func remove(ids: [String]) async { for id in ids { scheduled[id] = nil } }
    func pendingIDs() async -> Set<String> { Set(scheduled.keys) }
}

@MainActor final class StorageLifecycleTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !condition() && Date.now < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "lifecycle retry did not complete", file: file, line: line)
    }
    private func enqueue(_ id: UUID, in inbox: URL) throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: inbox.appendingPathComponent("\(id).m4a"))
        try JSONEncoder().encode(IncomingRecording(id: id, kind: .long, capturedAt: .now, duration: 1)).write(to: inbox.appendingPathComponent("\(id).json"))
    }

    func testNotesFailedOpenKeepsReceptionAndUnlockReplaysDurableInbox() async throws {
        let root = try temporary(), inbox = root.appendingPathComponent("Inbox"), blocker = root.appendingPathComponent("unavailable.sqlite3")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let pendingID = UUID(), incomingID = UUID()
        do {
            let repository = try NoteRepository(root: root)
            let source = root.appendingPathComponent("pending.m4a"); try Data([1]).write(to: source)
            _ = try repository.importRecording(id: pendingID, from: source, kind: .long, capturedAt: .now, duration: 1)
        }
        // Even an unavailable Inbox must not prevent WCSession activation/receiver installation.
        try Data([1]).write(to: inbox)
        var available = false, acknowledged: [UUID] = [], transcribed: [UUID] = []
        let receiver = try PhoneConnectivity(inbox: inbox, sendAcknowledgement: { id in
            XCTAssertNotNil(try? NoteRepository(root: root).notes.first { $0.id == id }, "ack requires durable metadata")
            acknowledged.append(id); return true
        })
        try FileManager.default.removeItem(at: inbox)
        try enqueue(incomingID, in: inbox)
        let model = NotesModel(settings: AppSettings(), transcribeWithSegments: { url, _ in
            transcribed.append(UUID(uuidString: url.deletingPathExtension().lastPathComponent)!)
            return TranscriptionOutput(text: "recovered transcript")
        }, voiceProfile: MyVoiceProfileModel(), root: root, openRepository: {
            if !available { _ = try DaybookDatabase(url: blocker) }
            return try NoteRepository(root: root)
        }, connectivity: receiver)
        XCTAssertNotNil(receiver.onReceive, "metadata open failure must not prevent installing Watch reception")
        receiver.drainInbox()
        await Task.yield()
        XCTAssertTrue(model.notes.isEmpty && acknowledged.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(incomingID).json").path))
        available = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await eventually { model.notes.count == 2 && acknowledged == [incomingID] && transcribed.count == 2 }
        XCTAssertEqual(Set(transcribed), [pendingID,incomingID], "pending processing resumes after storage recovery")
        let published = model.notes
        available = false
        model.refreshWatchStatus()
        XCTAssertEqual(model.notes, published, "transient reopen failure preserves published notes")
        available = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        model.refreshWatchStatus()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(acknowledged, [incomingID], "successful replay removes its durable sidecar")
        XCTAssertEqual(transcribed.count, 2, "repeated lifecycle retries do not restart completed processing")
    }

    func testV2ConnectivityStatusRecoversEmptyUnlockAndIsolatesCounterpart() throws {
        enum Locked: Error { case storage }
        let root = try temporary()
        let repository = try RecordingSessionRepository(root: root.appendingPathComponent("Audio"),
            database: DaybookDatabase(url: root.appendingPathComponent("db.sqlite3")))
        var locked = true
        let receiver = try RecordingChunkReceiver(root: root.appendingPathComponent("V2"), openRepository: {
            if locked { throw Locked.storage }; return repository
        }, send: { _ in })
        let binding = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: UUID(), nonce: UUID())
        receiver.setBinding(binding)
        let connectivity = try PhoneConnectivity(inbox: root.appendingPathComponent("Inbox"), recordingReceiver: receiver)
        XCTAssertThrowsError(try receiver.drain())
        XCTAssertTrue(connectivity.recordingSaveFailed, "real connectivity reads aggregate failed storage open")
        locked = false; try receiver.drain()
        XCTAssertFalse(connectivity.recordingSaveFailed, "empty successful unlock clears connectivity status")
        locked = true; XCTAssertThrowsError(try receiver.drain())
        let replacement = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: binding.watchID, nonce: UUID())
        receiver.setBinding(replacement)
        XCTAssertFalse(connectivity.recordingSaveFailed, "old counterpart failure cannot leak into replacement status")
    }

    func testV2WorkerImportsWhileLegacyRepositoryCannotOpen() async throws {
        let root = try temporary(), inbox = root.appendingPathComponent("Inbox")
        let source = root.appendingPathComponent("closed.m4a")
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.1 }
            try writer.write(from: buffer)
        }
        let info = try RecordingAudioFile.inspect(source)
        let chunk = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0,
            sessionStartedAt: .now, capturedAt: .now, timeZoneIdentifier: "UTC", sessionStartOffset: 0,
            frameCount: 1600, sampleRate: 16000, byteCount: info.byteCount, sha256: info.sha256,
            origin: .init(device: "Watch", deviceID: "", fileName: "closed.m4a", recordingTimeIsEstimated: false), location: nil)
        let databaseURL = DaybookDatabase.metadataURL(forRoot: root)
        let mediaRoot = root.appendingPathComponent("RecordingSessions")
        let saved = expectation(description: "durable V2 ACK while V1 is unavailable")
        let receiver = try RecordingChunkReceiver(root: inbox.appendingPathComponent("RecordingV2"), openRepository: {
            try RecordingSessionRepository(root: mediaRoot, database: DaybookDatabase(url: databaseURL))
        }, send: { _ in saved.fulfill() })
        let binding = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: UUID(), nonce: UUID())
        receiver.setBinding(binding)
        try receiver.stage(.init(binding: binding, payload: chunk), temporaryFile: source)
        let connectivity = try PhoneConnectivity(inbox: inbox, recordingReceiver: receiver)
        var transcriptionCount = 0
        let model = NotesModel(settings: AppSettings(), transcribeWithSegments: { _, _ in
            transcriptionCount += 1; return .init(text: "must not run for V2")
        }, voiceProfile: MyVoiceProfileModel(), root: root, openRepository: { throw URLError(.cannotOpenFile) }, connectivity: connectivity)
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertEqual(transcriptionCount, 0)
        let repository = try RecordingSessionRepository(root: mediaRoot, database: DaybookDatabase(url: databaseURL))
        XCTAssertEqual(try repository.chunks(sessionID: chunk.sessionID).count, 1)
        XCTAssertNotNil(try repository.receiptSavedAt(chunkID: chunk.id, pairingID: binding.counterpart.key))
    }

    func testDaybookDatabaseAndItsFolderAreExcludedFromDeviceBackup() throws {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = applicationSupport.appendingPathComponent("WristNotes", isDirectory: true)
        let folder = root.appendingPathComponent("Database", isDirectory: true)
        let databaseURL = folder.appendingPathComponent("daybook.sqlite3")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("LifeSources", isDirectory: true), withIntermediateDirectories: true)
        let legacyHealthSnapshot = root.appendingPathComponent("LifeSources/snapshots.json")
        try Data("{}".utf8).write(to: legacyHealthSnapshot)
        let database = try DaybookDatabase()
        try database.execute("CREATE TABLE IF NOT EXISTS backup_policy_probe (value TEXT)")
        defer { try? database.execute("DROP TABLE backup_policy_probe") }

        let rootValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let folderValues = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(rootValues.isExcludedFromBackup, true, "legacy LifeSources and Conversations files share this excluded tree")
        XCTAssertEqual(folderValues.isExcludedFromBackup, true, "the directory must exclude SQLite files recreated later")
        XCTAssertEqual(fileValues.isExcludedFromBackup, true, "the live database must be excluded from iCloud device backup")
    }

    func testFailedWatchImportReplaysOnForegroundAndAcknowledgesOnlyAfterCommit() async throws {
        let root = try temporary(), inbox = root.appendingPathComponent("Inbox"), id = UUID()
        let database = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try database.execute("CREATE TRIGGER fail_receive BEFORE INSERT ON voice_notes BEGIN SELECT RAISE(ABORT,'injected'); END")
        var acknowledged: [UUID] = [], processing = 0
        let receiver = try PhoneConnectivity(inbox: inbox, sendAcknowledgement: { id in
            XCTAssertEqual(try? database.query("SELECT id FROM voice_notes").count, 1)
            acknowledged.append(id); return true
        })
        let model = NotesModel(settings: AppSettings(), transcribeWithSegments: { _, _ in
            processing += 1; return TranscriptionOutput(text: "accepted")
        }, voiceProfile: MyVoiceProfileModel(), root: root, connectivity: receiver)
        try enqueue(id, in: inbox)
        receiver.drainInbox()
        try await eventually { model.errorMessage?.contains("录音接收失败") == true }
        XCTAssertTrue(acknowledged.isEmpty && model.notes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).json").path))
        try database.execute("DROP TRIGGER fail_receive")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await eventually { acknowledged == [id] && processing == 1 }
        XCTAssertEqual(try database.query("SELECT id FROM voice_notes").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(id).json").path))
    }

    func testRecoveryRetriesInterruptedProcessingDespiteVisibleWriteFailure() async throws {
        let root = try temporary(), repository = try NoteRepository(root: root), id = UUID()
        let source = root.appendingPathComponent("interrupted.m4a"); try Data([1]).write(to: source)
        _ = try repository.importRecording(id: id, from: source, kind: .long, capturedAt: .now, duration: 1)
        try repository.update(id: id) { $0.transcriptionState = .running }
        let database = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try database.execute("CREATE TRIGGER fail_processing BEFORE UPDATE ON voice_notes BEGIN SELECT RAISE(ABORT,'injected'); END")
        var processing = 0
        let model = NotesModel(settings: AppSettings(), connectWatch: false, transcribeWithSegments: { _, _ in
            processing += 1; return TranscriptionOutput(text: "resumed")
        }, voiceProfile: MyVoiceProfileModel(), root: root)
        try await eventually { model.note(id)?.transcriptionState == .failed && model.errorMessage != nil }
        XCTAssertEqual(processing, 0, "failed running-state commit must not start inference")
        try database.execute("DROP TRIGGER fail_processing")
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await eventually { model.note(id)?.transcriptionState == .ready && processing == 1 }
        XCTAssertEqual(try NoteRepository(root: root).notes.first?.transcript, "resumed")
    }

    func testPhotoRetryPreservesPublishedMomentsAndUnlockReopens() async throws {
        let root = try temporary(), blocker = root.appendingPathComponent("unavailable.sqlite3")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        var available = true
        let model = PhotoLibraryModel(root: root, openRepository: {
            if !available { _ = try DaybookDatabase(url: blocker) }
            return try PhotoRepository(root: root)
        })
        let moment = try model.save(caption: "preserve", photos: [PhotoImport(jpegData: Data([0xff,0xd8,0xff,0xe0,0xff,0xd9]))])
        available = false; model.reload()
        XCTAssertEqual(model.moments, [moment], "transient open failure preserves published metadata")
        XCTAssertNotNil(model.errorMessage)
        available = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await eventually { model.errorMessage == nil }
        XCTAssertEqual(model.moments, [moment])
        _ = try model.save(caption: "after retry", photos: [PhotoImport(jpegData: Data([0xff,0xd8,0xff,0xe0,0xff,0xd9]))])
        XCTAssertEqual(try PhotoRepository(root: root).moments.count, 2)
    }

    func testReminderFailedOpenRecoversWithoutRestart() async throws {
        let root = try temporary().appendingPathComponent("Reminders")
        try Data([1]).write(to: root)
        let scheduler = LifecycleScheduler()
        let store = DaybookReminderStore(root: root, scheduler: scheduler)
        XCTAssertFalse(store.isAvailable)
        XCTAssertNotNil(store.errorMessage)
        await store.refreshAuthorization()
        await Task.yield()
        try FileManager.default.removeItem(at: root)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await eventually { store.isAvailable && !store.isBusy }
        XCTAssertTrue(store.isAvailable, "reminder store must retry a failed protected-storage open")
        let accepted = await store.confirm(title: "Recovered reminder", scheduledAt: Date.now.addingTimeInterval(600))
        XCTAssertTrue(accepted)
        XCTAssertEqual(try DaybookReminderRepository(root: root).items.count, 1)
        XCTAssertEqual(scheduler.scheduled.count, 1)
    }
}
