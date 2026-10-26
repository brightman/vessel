import AVFAudio
import BRRecorderCore
import XCTest
import BRRecorderOpus
@testable import WiseNote

@MainActor final class RingIntegrationTests: XCTestCase {
    private let hardware = BRRecorderDevice(sn: "SYNTHETIC-RING", address: "00000000-0000-0000-0000-000000000001", name: "EurekaRing")

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ name: String = "normal.opus", date: Date = Date(timeIntervalSince1970: 1_790_000_000),
                      kind: BRRecorderFileKind = .recording) -> BRRecorderFile {
        BRRecorderFile(name: name, byteCount: 4000, recordedAt: date, expectedDuration: 1, kind: kind)
    }
    private func legacyFixture() throws -> URL {
        try XCTUnwrap(Bundle(for: RingIntegrationTests.self).url(forResource: "sdk-opus-16k-mono", withExtension: "bin"))
    }
    private func wave(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("synthetic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            for channel in 0..<2 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.1 }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        var output: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try output!.write(from: buffer)
        output = nil
        return url
    }
    private func connect(_ model: EurekaRingModel) async {
        await model.connect(hardware)
        XCTAssertTrue(model.isConnected, model.errorMessage ?? "")
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Local Ring operation did not finish")
    }

    func testAppRecordingAndPhysicalButtonStopAutomaticallySync() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model); await model.toggleRecording()
        XCTAssertTrue(model.isRecording)
        await model.synchronize()
        XCTAssertEqual(sdk.transfers, 0)
        sdk.files = [file()]
        await model.toggleRecording()
        try await waitFor { !model.isBusy && saver.repository.notes.count == 1 }
        XCTAssertNil(model.errorMessage, "App stop: \(model.status)")
        XCTAssertEqual(saver.repository.notes.count, 1, "App stop: \(model.status)")
        sdk.recording = true; sdk.onEvent?(.recordingStarted(true))
        XCTAssertTrue(model.isRecording)
        sdk.files.append(file("physical.opus"))
        sdk.recording = false; sdk.onEvent?(.recordingStopped)
        try await waitFor { !model.isBusy && saver.repository.notes.count == 2 }
        XCTAssertNil(model.errorMessage, "Physical stop: \(model.status)")
        XCTAssertEqual(saver.repository.notes.count, 2, "Physical stop: \(model.status)")
        XCTAssertEqual(sdk.transfers, 2)
        XCTAssertFalse(model.isRecording)
    }

    func testStoreRestartStableIdentityAndFormatGeneration() async throws {
        let root = try temporary()
        let store = try RingTransferStore(root: root)
        let original = try store.enqueue([file()], deviceID: hardware.id)[0]
        try store.setStage(original.id, .converting)
        let reopened = try RingTransferStore(root: root)
        let recovered = try reopened.enqueue([file()], deviceID: hardware.id)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].id, original.id)
        XCTAssertEqual(recovered[0].stage, .queued)
        try reopened.setStage(original.id, .saved)
        XCTAssertTrue(try reopened.enqueue([file()], deviceID: hardware.id).isEmpty)
        try reopened.update { $0.generations[hardware.id] = UUID() }
        XCTAssertNotEqual(try reopened.enqueue([file()], deviceID: hardware.id)[0].id, original.id)
        XCTAssertThrowsError(try reopened.enqueue([file("../escape.opus")], deviceID: hardware.id))
    }

    func testSyncSavesRecordedDateAndDoesNotReimportDeletedNotes() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model); await model.synchronize()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(saver.repository.notes.count, 1)
        let note = try XCTUnwrap(saver.repository.notes.first)
        XCTAssertEqual(note.capturedAt, file().recordedAt)
        XCTAssertEqual(note.origin?.device, "EurekaRing")
        XCTAssertEqual(note.origin?.recordingTimeIsEstimated, false)
        let audio = try AVAudioFile(forReading: saver.repository.audioURL(for: note))
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(sdk.transfers, 1)
        try saver.repository.delete(id: note.id)
        await model.synchronize()
        XCTAssertTrue(saver.repository.notes.isEmpty)
        XCTAssertEqual(sdk.transfers, 1)
        XCTAssertEqual(saver.attempts, 1)
    }

    func testFailedSaveSurvivesRestartWithoutDownloadingAgain() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library")); saver.failNext = true
        let ringRoot = root.appendingPathComponent("Ring")
        let first = EurekaRingModel(device: sdk, root: ringRoot)
        first.configure(save: saver.save, exists: saver.exists)
        await connect(first); await first.synchronize()
        XCTAssertNotNil(first.errorMessage)
        XCTAssertEqual(first.pendingCount, 1)
        let id = try XCTUnwrap(try RingTransferStore(root: ringRoot).state.jobs.first?.id)
        let restarted = EurekaRingModel(device: sdk, root: ringRoot)
        restarted.configure(save: saver.save, exists: saver.exists)
        await connect(restarted); await restarted.synchronize()
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(sdk.transfers, 1)
        XCTAssertEqual(saver.repository.notes.first?.id, id)
        XCTAssertEqual(restarted.pendingCount, 0)
    }

    func testCrashAfterLibrarySaveRecoversReceiptWithoutDownloadingOrSavingAgain() async throws {
        let root = try temporary()
        let input = try legacyFixture()
        let ringRoot = root.appendingPathComponent("Ring")
        let journal = try RingTransferStore(root: ringRoot)
        let job = try journal.enqueue([file()], deviceID: hardware.id)[0]
        try journal.setStage(job.id, .converting)
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let audio = try await BRAudioNormalizer.normalize(input: input, output: root.appendingPathComponent("saved.m4a"))
        try saver.save(job, audio.url, audio.duration)
        let sdk = FakeRingDevice(input: input, files: [file()])
        let restarted = EurekaRingModel(device: sdk, root: ringRoot)
        restarted.configure(save: saver.save, exists: saver.exists)
        await connect(restarted); await restarted.synchronize()
        XCTAssertEqual(sdk.transfers, 0)
        XCTAssertEqual(saver.attempts, 1)
        XCTAssertEqual(saver.repository.notes.count, 1)
        XCTAssertEqual(restarted.pendingCount, 0)
    }

    func testDisconnectDuringTransferNeverSavesPartialAudio() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        sdk.duringTransfer = { sdk.onEvent?(.connection(false)) }
        await connect(model); await model.synchronize()
        XCTAssertFalse(model.isConnected)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(saver.attempts, 0)
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertNil(model.operation)
        sdk.duringTransfer = nil
        await connect(model); await model.synchronize()
        XCTAssertEqual(saver.repository.notes.count, 1)
    }

    func testPartialListRetainsKnownFilesAndDoesNotSetLastSync() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file(), file("other.opus")])
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        await connect(model); await model.refresh()
        XCTAssertEqual(model.files.count, 2)
        sdk.files = [file()]; sdk.complete = false
        await model.refresh()
        XCTAssertEqual(model.files.count, 2)
        XCTAssertEqual(model.pendingCount, 2)
        XCTAssertFalse(model.listIsComplete)
        XCTAssertNil(model.lastSync)
    }

    func testUnknownFormatResultIsNotAutomaticallyRetried() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()]); sdk.failFormat = true
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        await connect(model); await model.format()
        XCTAssertTrue(model.needsFormatReconciliation)
        await model.format(); await model.foreground()
        XCTAssertEqual(sdk.formats, 1)
        await model.reconcileFormat()
        XCTAssertFalse(model.needsFormatReconciliation)
        XCTAssertEqual(sdk.formats, 1)
        XCTAssertEqual(model.files.count, 1)
    }

    func testDisconnectShowsReconnectAndKeepsUnknownFormatReceiptAcrossRelaunch() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()]); sdk.failFormat = true
        let model = EurekaRingModel(device: sdk, root: root)
        await connect(model); await model.format()
        XCTAssertEqual(model.primaryAction, .reconcileFormat)
        model.disconnect()
        XCTAssertEqual(model.primaryAction, .reconnect)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.battery)
        XCTAssertEqual(model.storage, "等待连接")
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertFalse(model.listIsComplete)
        XCTAssertTrue(model.needsFormatReconciliation)
        XCTAssertNotNil(model.binding)
        let relaunched = EurekaRingModel(device: sdk, root: root)
        XCTAssertEqual(relaunched.primaryAction, .reconnect)
        XCTAssertTrue(relaunched.needsFormatReconciliation)
        await connect(relaunched)
        XCTAssertEqual(relaunched.primaryAction, .reconcileFormat)
        await relaunched.reconcileFormat()
        XCTAssertEqual(relaunched.primaryAction, .controls)
        XCTAssertFalse(relaunched.needsFormatReconciliation)
        XCTAssertEqual(sdk.formats, 1, "Reconnect/reconciliation must never resend format")
        XCTAssertEqual(sdk.files.count, 1)
    }

    func testDisconnectDuringFormatReleasesPageAndLateReplyDoesNotFinishNewConnect() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let model = EurekaRingModel(device: sdk, root: try temporary())
        let formatGate = RingTestGate(), connectGate = RingTestGate()
        defer { formatGate.release(); connectGate.release() }
        await connect(model)
        sdk.duringFormat = { await formatGate.wait() }
        let formatting = Task { await model.format() }
        try await waitFor { formatGate.isWaiting }
        sdk.onEvent?(.connection(false))
        XCTAssertEqual(model.primaryAction, .reconnect)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.needsFormatReconciliation)
        sdk.beforeConnect = { await connectGate.wait() }
        let reconnecting = Task { await model.connect(self.hardware) }
        try await waitFor { connectGate.isWaiting }
        XCTAssertEqual(model.operation, .connecting)
        formatGate.release(); await formatting.value
        XCTAssertEqual(model.operation, .connecting, "Old defer must not release the new operation")
        XCTAssertTrue(model.needsFormatReconciliation, "A late format acknowledgement cannot clear uncertainty after disconnect")
        connectGate.release(); await reconnecting.value
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.primaryAction, .reconcileFormat)
        XCTAssertEqual(sdk.formats, 1)
    }

    func testLateFormatReconciliationCannotClearReceiptAfterDisconnect() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()]); sdk.failFormat = true
        let model = EurekaRingModel(device: sdk, root: try temporary())
        await connect(model); await model.format()
        let gate = RingTestGate(); defer { gate.release() }
        sdk.beforeList = { await gate.wait() }
        let query = Task { await model.reconcileFormat() }
        try await waitFor { gate.isWaiting }
        sdk.onEvent?(.connection(false))
        XCTAssertEqual(model.primaryAction, .reconnect)
        XCTAssertFalse(model.isBusy)
        sdk.files = []; gate.release(); await query.value
        XCTAssertTrue(model.needsFormatReconciliation)
        XCTAssertFalse(model.listIsComplete)
        XCTAssertEqual(model.primaryAction, .reconnect)
        sdk.beforeList = nil
        await connect(model); await model.reconcileFormat()
        XCTAssertEqual(model.primaryAction, .controls)
        XCTAssertEqual(sdk.formats, 1)
    }

    func testLateBatteryResponseDoesNotRestoreDisconnectedDeviceInformation() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let model = EurekaRingModel(device: sdk, root: try temporary())
        await connect(model)
        let gate = RingTestGate(); defer { gate.release() }
        sdk.beforeBattery = { await gate.wait() }
        let refresh = Task { await model.refresh() }
        try await waitFor { gate.isWaiting }
        sdk.onEvent?(.connection(false))
        let disconnectedStatus = model.status
        gate.release(); await refresh.value
        XCTAssertEqual(model.primaryAction, .reconnect)
        XCTAssertNil(model.battery)
        XCTAssertEqual(model.storage, "等待连接")
        XCTAssertFalse(model.listIsComplete)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.status, disconnectedStatus)
    }

    func testBluetoothOffResetsRecordingAndConnectionPageWithoutErasingFormatReceipt() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()]); sdk.failFormat = true
        let model = EurekaRingModel(device: sdk, root: try temporary())
        await connect(model); await model.format()
        sdk.flashing = true; sdk.onEvent?(.flashIdeaStarted(success: true))
        await model.reconcileFormat()
        XCTAssertTrue(model.needsFormatReconciliation)
        sdk.onEvent?(.bluetooth("poweredOff"))
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isFlashIdeaRecording)
        XCTAssertFalse(model.flashIdeaSupported)
        XCTAssertEqual(model.primaryAction, .reconnect)
        XCTAssertTrue(model.needsFormatReconciliation)
        XCTAssertEqual(model.status, "请开启 iPhone 蓝牙。")
        XCTAssertEqual(sdk.formats, 1)
    }

    func testInitialDisconnectedEventDoesNotCancelFirstConnectionHandshake() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [])
        let model = EurekaRingModel(device: sdk, root: try temporary())
        sdk.beforeConnect = { sdk.onEvent?(.connection(false)); sdk.onEvent?(.connection(true)) }
        await connect(model)
        XCTAssertEqual(model.primaryAction, .controls)
        XCTAssertFalse(model.isBusy)
    }

    func testTransportLossDuringHandshakeDoesNotPublishLateReadyResult() async throws {
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [])
        let model = EurekaRingModel(device: sdk, root: try temporary())
        sdk.beforeConnect = { sdk.onEvent?(.connection(true)); sdk.onEvent?(.connection(false)) }
        await model.connect(hardware)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.binding)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.primaryAction, .scan)
    }

    func testDisconnectCancelsConversionAndReconnectReusesDurableRawAudio() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        var conversions = 0, cancelled = false
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"), normalize: { raw, converted, progress in
            conversions += 1
            if conversions == 1 {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = true; throw error }
            }
            return try await BRAudioNormalizer.normalize(input: raw, output: converted, progress: progress)
        })
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model)
        let syncing = Task { await model.synchronize() }
        try await waitFor { conversions == 1 }
        sdk.onEvent?(.connection(false))
        XCTAssertFalse(model.isBusy)
        await syncing.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(saver.repository.notes.isEmpty)
        await connect(model); await model.synchronize()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(saver.repository.notes.count, 1)
        XCTAssertEqual(sdk.transfers, 1)
    }

    func testUnbindPreservesLocalRecordings() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model); await model.synchronize(); await model.unbind()
        XCTAssertNil(model.binding)
        XCTAssertEqual(saver.repository.notes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saver.repository.audioURL(for: try XCTUnwrap(saver.repository.notes.first)).path))
        XCTAssertEqual(sdk.unbinds, 1)
        XCTAssertEqual(sdk.files.count, 1)
    }

    func testFormatPreservesPhoneNotesAndAcceptsNewSameNameRecording() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model); await model.synchronize(); await model.format()
        XCTAssertEqual(saver.repository.notes.count, 1)
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(sdk.formats, 1)
        sdk.files = [file()]
        await model.synchronize()
        XCTAssertEqual(saver.repository.notes.count, 2)
        XCTAssertNotEqual(try XCTUnwrap(saver.repository.notes.first).id, try XCTUnwrap(saver.repository.notes.last).id)
    }

    func testOpusDirectToAACAndTruncatedPacketRejection() async throws {
        let root = try temporary()
        var error: Int32 = 0
        let encoder = try XCTUnwrap(opus_encoder_create(16_000, 1, OPUS_APPLICATION_VOIP, &error))
        defer { opus_encoder_destroy(encoder) }
        XCTAssertEqual(error, OPUS_OK)
        var packets = Data()
        var pcm = [Int16](repeating: 0, count: 320)
        for frame in 0..<50 {
            for index in 0..<320 { pcm[index] = Int16(sin(Double(frame * 320 + index) * 2 * .pi * 440 / 16_000) * 3000) }
            var packet = [UInt8](repeating: 0, count: 80)
            let count = opus_encode(encoder, &pcm, 320, &packet, 80)
            XCTAssertGreaterThan(count, 0)
            XCTAssertEqual(opus_packet_pad(&packet, count, 80), OPUS_OK)
            packets.append(contentsOf: packet)
        }
        let raw = root.appendingPathComponent("synthetic.opus")
        try packets.write(to: raw)
        let output = root.appendingPathComponent("normalized.m4a")
        let normalized = try await BRAudioNormalizer.normalize(input: raw, output: output)
        XCTAssertEqual(normalized.duration, 1, accuracy: 0.15)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let truncated = root.appendingPathComponent("truncated.opus")
        try packets.dropLast().write(to: truncated)
        do {
            _ = try await BRAudioNormalizer.normalize(input: truncated, output: root.appendingPathComponent("bad.m4a"))
            XCTFail("Truncated Opus must not enter the recording library")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad.m4a").path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: truncated.path))
    }

    func testDecodesLegacyVendorSDKOpusFixture() async throws {
        let root = try temporary()
        let input = try XCTUnwrap(Bundle(for: RingIntegrationTests.self).url(forResource: "sdk-opus-16k-mono", withExtension: "bin"))
        let result = try await BRAudioNormalizer.normalize(input: input, output: root.appendingPathComponent("legacy.m4a"))
        XCTAssertEqual(result.duration, 1, accuracy: 0.15)
        let audio = try AVAudioFile(forReading: result.url)
        let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
        try audio.read(into: pcm)
        let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.03)
    }

    func testResamplesReadableStereoAudioToMonoAAC() async throws {
        let root = try temporary()
        let input: URL
        do { input = try wave(in: root) }
        catch { XCTFail("Synthetic PCM fixture creation: \(error)"); return }
        let original = try AVAudioFile(forReading: input)
        XCTAssertEqual(original.length, 48_000)
        let result: BRNormalizedAudio
        do { result = try await BRAudioNormalizer.normalize(input: input, output: root.appendingPathComponent("resampled.m4a")) }
        catch { XCTFail("Readable PCM conversion: \(error)"); return }
        let audio = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(result.duration, 1, accuracy: 0.15)
    }

    func testFlashClassificationAndLegacyJournalDecoding() throws {
        XCTAssertEqual(BRRecorderFileKind(sdkFileType: "FlashIdea"), .flashIdea)
        XCTAssertEqual(BRRecorderFileKind(sdkFileType: "Normal"), .recording)
        XCTAssertEqual(BRRecorderFileKind(sdkFileType: "Normal", fileName: "F-legacy.opus"), .flashIdea)
        XCTAssertNil(BRRecorderFileKind(sdkFileType: "Earphone"))
        XCTAssertNil(BRRecorderFileKind(sdkFileType: "Earphone", fileName: "F-ignored.opus"))
        let store = try RingTransferStore(root: temporary())
        let job = try store.enqueue([file()], deviceID: hardware.id)[0]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        var info = try XCTUnwrap(json["file"] as? [String: Any]); info.removeValue(forKey: "kind"); json["file"] = info
        let legacy = try JSONDecoder().decode(RingTransferJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.file.kind, .recording)
        XCTAssertEqual(legacy.recordingKind, .long)
        XCTAssertEqual(legacy.id, job.id)
    }

    func testOfflineFlashSyncKeepsThoughtKindAndDeduplicates() async throws {
        let root = try temporary()
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file(), file("F-offline.opus", kind: .flashIdea)])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model); await model.synchronize()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(saver.repository.notes.filter { $0.kind == .thought }.count, 1)
        XCTAssertEqual(saver.repository.notes.filter { $0.kind == .long }.count, 1)
        await model.synchronize()
        XCTAssertEqual(sdk.transfers, 2)
        XCTAssertEqual(saver.repository.notes.count, 2)
    }

    func testFlashEndUsesValidatedRealtimeAudioWithoutDuplicateImport() async throws {
        let root = try temporary(), input = try legacyFixture()
        let flash = file("F-live.opus", kind: .flashIdea)
        let sdk = FakeRingDevice(input: input, files: [])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model)
        sdk.flashing = true; sdk.onEvent?(.flashIdeaStarted(success: true))
        XCTAssertTrue(model.isFlashIdeaRecording)
        XCTAssertTrue(model.isRecording)
        await model.toggleRecording(); await model.synchronize(); await model.format(); await model.unbind()
        XCTAssertEqual(sdk.transfers, 0); XCTAssertEqual(sdk.formats, 0); XCTAssertEqual(sdk.unbinds, 0)
        sdk.files = [flash]; sdk.flashing = false
        sdk.onEvent?(.flashIdeaEnded(file: flash, audioURL: input))
        try await waitFor { !model.isBusy && saver.repository.notes.count == 1 }
        XCTAssertEqual(saver.repository.notes.first?.kind, .thought)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(sdk.transfers, 0)
        sdk.onEvent?(.flashIdeaEnded(file: flash, audioURL: input))
        try await waitFor { !model.isBusy }
        await model.synchronize()
        XCTAssertEqual(saver.attempts, 1); XCTAssertEqual(sdk.transfers, 0)
    }

    func testMissingRealtimeFlashAudioFallsBackToBLE() async throws {
        let root = try temporary()
        let flash = file("F-fallback.opus", kind: .flashIdea)
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [flash])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        await connect(model)
        sdk.onEvent?(.flashIdeaEnded(file: flash, audioURL: nil))
        try await waitFor { !model.isBusy && saver.repository.notes.count == 1 }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(sdk.transfers, 1)
        XCTAssertEqual(saver.repository.notes.first?.kind, .thought)
    }

    func testFlashInterruptsTransferAndLatePreviousEndDoesNotStopNextFlash() async throws {
        let root = try temporary()
        let flash = file("F-next.opus", kind: .flashIdea)
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file()])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(save: saver.save, exists: saver.exists)
        sdk.duringTransfer = { sdk.flashing = true; sdk.onEvent?(.flashIdeaStarted(success: true)) }
        await connect(model); await model.synchronize()
        XCTAssertTrue(model.isRecording)
        XCTAssertTrue(saver.repository.notes.isEmpty)
        sdk.onEvent?(.flashIdeaEnded(file: nil, audioURL: nil))
        XCTAssertTrue(model.isFlashIdeaRecording)
        await model.format(); await model.unbind()
        XCTAssertEqual(sdk.formats, 0); XCTAssertEqual(sdk.unbinds, 0)
        sdk.duringTransfer = nil; sdk.files.append(flash); sdk.flashing = false
        sdk.onEvent?(.flashIdeaEnded(file: flash, audioURL: nil))
        try await waitFor { !model.isBusy && saver.repository.notes.count == 2 }
        XCTAssertEqual(saver.repository.notes.filter { $0.kind == .thought }.count, 1)
    }

    func testStagedFlashSurvivesRestartAndEnrichesDeviceTimestamp() async throws {
        let root = try temporary(), input = try legacyFixture()
        let ringRoot = root.appendingPathComponent("Ring")
        let store = try RingTransferStore(root: ringRoot)
        let uncertain = BRRecorderFile(name: "F-restart.opus", kind: .flashIdea)
        try store.stageFlashAudio(uncertain, from: input, deviceID: hardware.id)
        let id = try XCTUnwrap(store.state.jobs.first?.id)
        let flash = file(uncertain.name, kind: .flashIdea)
        let sdk = FakeRingDevice(input: input, files: [flash])
        let saver = try Saver(root: root.appendingPathComponent("Library"))
        let restarted = EurekaRingModel(device: sdk, root: ringRoot)
        restarted.configure(save: saver.save, exists: saver.exists)
        await connect(restarted); await restarted.synchronize()
        XCTAssertNil(restarted.errorMessage)
        XCTAssertEqual(sdk.transfers, 0)
        XCTAssertEqual(saver.repository.notes.first?.id, id)
        XCTAssertEqual(saver.repository.notes.first?.capturedAt, flash.recordedAt)
        XCTAssertEqual(saver.repository.notes.first?.origin?.recordingTimeIsEstimated, false)
        XCTAssertEqual(saver.repository.notes.first?.kind, .thought)
    }

    private func customSettings() throws -> AppSettings {
        let suite = "RingFlashTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(AIConfiguration(mode: .custom, model: "must-not-be-used", baseURL: "https://example.invalid")), forKey: "aiConfiguration")
        return AppSettings(defaults: defaults, secrets: RingNoRemoteSecrets())
    }

    func testFlashAutomaticallyRunsLocalAIEvenWithCustomSettingsAndPersistsResults() async throws {
        let root = try temporary()
        let repository = try NoteRepository(root: root.appendingPathComponent("Library"))
        var asrCalls = 0, summaryCalls = 0
        let settings = try customSettings()
        let notes = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribe: { _, _ in asrCalls += 1; return "合成测试：明天整理设计草图。" },
            summarizeLocally: { text, kind in
                summaryCalls += 1; XCTAssertEqual(kind, .thought); XCTAssertTrue(text.contains("设计草图"))
                return "待办：明天整理设计草图。"
            })
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file("F-ai.opus", kind: .flashIdea)])
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(notes: notes)
        await connect(model); await model.synchronize()
        try await waitFor { notes.notes.first?.summaryState == .ready }
        let note = try XCTUnwrap(notes.notes.first)
        XCTAssertTrue(note.usesLocalThoughtAI)
        XCTAssertEqual(notes.summaryConfiguration(for: note).mode, .local)
        XCTAssertEqual(settings.ai.mode, .custom)
        let reloaded = try NoteRepository(root: root.appendingPathComponent("Library"))
        XCTAssertEqual(reloaded.notes.first?.transcript, note.transcript)
        XCTAssertEqual(reloaded.notes.first?.summary, "待办：明天整理设计草图。")
        await model.synchronize()
        XCTAssertEqual(asrCalls, 1); XCTAssertEqual(summaryCalls, 1)
    }

    func testUnavailableLocalModelRetainsFlashAudioAndTranscriptWithoutRemoteFallback() async throws {
        let root = try temporary()
        let repository = try NoteRepository(root: root.appendingPathComponent("Library"))
        let notes = NotesModel(repository: repository, settings: try customSettings(), connectWatch: false,
            transcribe: { _, _ in "合成闪念原文" }, summarizeLocally: { _, _ in throw SummaryFailure.unavailable })
        let sdk = FakeRingDevice(input: try legacyFixture(), files: [file("F-unavailable.opus", kind: .flashIdea)])
        let model = EurekaRingModel(device: sdk, root: root.appendingPathComponent("Ring"))
        model.configure(notes: notes)
        await connect(model); await model.synchronize()
        try await waitFor { notes.notes.first?.summaryState == .unavailable }
        let note = try XCTUnwrap(notes.notes.first)
        XCTAssertEqual(note.transcriptionState, .ready)
        XCTAssertEqual(note.transcript, "合成闪念原文")
        XCTAssertTrue(note.summary.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.audioURL(for: note).path))
    }

    func testLocalFlashSummaryResumesAfterRelaunch() async throws {
        let root = try temporary(), repository = try NoteRepository(root: root.appendingPathComponent("Library"))
        let audio = try await BRAudioNormalizer.normalize(input: legacyFixture(), output: root.appendingPathComponent("flash.m4a"))
        let id = UUID()
        try repository.importRecording(id: id, from: audio.url, kind: .thought, capturedAt: .now, duration: audio.duration,
            origin: RecordingOrigin(device: "EurekaRing", deviceID: hardware.id, fileName: "F-resume.opus", recordingTimeIsEstimated: false))
        try repository.update(id: id) { $0.transcript = "合成恢复测试"; $0.transcriptionState = .ready; $0.summaryState = .running }
        let notes = NotesModel(repository: repository, settings: try customSettings(), connectWatch: false,
            transcribe: { _, _ in XCTFail("Ready transcript must not be transcribed again"); return "" },
            summarizeLocally: { _, _ in "恢复后本地整理" })
        try await waitFor { notes.note(id)?.summaryState == .ready }
        XCTAssertEqual(repository.notes.first?.summary, "恢复后本地整理")
    }

}

@MainActor private final class Saver {
    let repository: NoteRepository
    var attempts = 0
    var failNext = false
    init(root: URL) throws { repository = try NoteRepository(root: root) }
    func exists(_ id: UUID) -> Bool { repository.notes.contains { $0.id == id } }
    func save(_ job: RingTransferJob, _ url: URL, _ duration: Double) throws {
        attempts += 1
        if failNext { failNext = false; throw NSError(domain: "SyntheticDiskFull", code: 1) }
        try repository.importRecording(id: job.id, from: url, kind: job.recordingKind, capturedAt: job.capturedAt, duration: duration,
            origin: RecordingOrigin(device: "EurekaRing", deviceID: job.deviceID, fileName: job.file.name,
                recordingTimeIsEstimated: job.file.recordedAt == nil))
    }
}

@MainActor private final class FakeRingDevice: BRRecordingDevice {
    var onEvent: ((BRRecorderEvent) -> Void)?
    let input: URL
    var files: [BRRecorderFile]
    var complete = true
    var recording = false
    var flashing = false
    var flashIdeaSupported = true
    var transfers = 0
    var formats = 0
    var unbinds = 0
    var failFormat = false
    var duringTransfer: (() -> Void)?
    var beforeConnect: (() async -> Void)?
    var beforeBattery: (() async -> Void)?
    var beforeList: (() async -> Void)?
    var duringFormat: (() async -> Void)?
    init(input: URL, files: [BRRecorderFile]) { self.input = input; self.files = files }
    func initialize() {}
    func scan() {}
    func stopScan() {}
    func connect(device: BRRecorderDevice, appUUID: String) async throws -> BRRecorderBinding {
        await beforeConnect?()
        return BRRecorderBinding(device: device, appUUID: "synthetic-binding")
    }
    func disconnect() { onEvent?(.connection(false)) }
    func syncTime() async throws {}
    func battery() async throws -> Int { await beforeBattery?(); return 80 }
    func storageDescription() async throws -> String { "Synthetic storage" }
    func isRecording() -> Bool { recording || flashing }
    func isFlashIdeaRecording() -> Bool { flashing }
    func startRecording() async throws { recording = true; onEvent?(.recordingStarted(true)) }
    func stopRecording() async throws { recording = false; onEvent?(.recordingStopped) }
    func listFiles() async throws -> BRRecorderFileList { await beforeList?(); return BRRecorderFileList(files: files, isComplete: complete) }
    func openSync() async throws {}
    func closeSync() async throws {}
    func transfer(_ file: BRRecorderFile) async throws -> URL {
        transfers += 1; duringTransfer?()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString).opus")
        try FileManager.default.copyItem(at: input, to: url)
        return url
    }
    func unbind() async throws { unbinds += 1 }
    func format() async throws {
        formats += 1
        await duringFormat?()
        if failFormat { throw BRRecorderFailure.sdk(code: "SYNTHETIC_TIMEOUT", message: "timeout") }
        files = []
    }
}

@MainActor private final class RingTestGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { let pending = waiter; waiter = nil; pending?.resume() }
}

private struct RingNoRemoteSecrets: SecretStore {
    func read() throws -> String { XCTFail("Ring flash AI must never read a remote API key"); throw SummaryFailure.unavailable }
    func write(_ value: String) throws { XCTFail("Ring flash AI must never write a remote API key") }
}
