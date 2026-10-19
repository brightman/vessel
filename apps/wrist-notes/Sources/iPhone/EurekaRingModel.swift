import AVFAudio
import BRRecorderCore
import Combine
import Foundation
import UIKit

@MainActor final class EurekaRingModel: ObservableObject {
    enum Operation { case connecting, refreshing, recording, syncing, unbinding, formatting }
    enum PrimaryAction { case scan, reconnect, controls, reconcileFormat }
    @Published private(set) var binding: BRRecorderBinding?
    @Published private(set) var discovered: [BRRecorderDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFlashIdeaRecording = false
    @Published private(set) var flashIdeaSupported = false
    @Published private(set) var operation: Operation?
    @Published private(set) var battery: Int?
    @Published private(set) var storage = "尚未读取"
    @Published private(set) var files: [BRRecorderFile] = []
    @Published private(set) var listIsComplete = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var progress: Double?
    @Published private(set) var status = "连接 EurekaRing，用硬件记录声音。"
    @Published private(set) var lastSync: Date?
    @Published private(set) var needsFormatReconciliation = false
    @Published var errorMessage: String?

    private let device: any BRRecordingDevice
    private var store: RingTransferStore?
    private var save: ((RingTransferJob, URL, Double) throws -> Void)?
    private var exists: ((UUID) -> Bool)?
    private var scanTask: Task<Void, Never>?
    private var syncAfterStop = false
    private var manuallyDisconnected = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundExpired = false
    private var activeProgressID: UUID?
    private var activeTransferName: String?
    private var connectionRevision = UUID()
    private var transportIsConnected = false
    private var conversionTask: Task<BRNormalizedAudio, Error>?
    private let normalize: (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> BRNormalizedAudio

    init(device: (any BRRecordingDevice)? = nil, root: URL? = nil,
         normalize: @escaping (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> BRNormalizedAudio = {
             try await BRAudioNormalizer.normalize(input: $0, output: $1, progress: $2)
         }) {
        self.device = device ?? BRRecorderClient(); self.normalize = normalize
        do {
            let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WiseNote/Ring", isDirectory: true)
            let store = try RingTransferStore(root: root)
            self.store = store
            binding = store.state.binding
            updateSnapshot()
        } catch { errorMessage = "无法打开 Ring 本地同步记录：\(error.localizedDescription)" }
        self.device.onEvent = { [weak self] event in self?.receive(event) }
    }

    func configure(notes: NotesModel) {
        configure(save: { [weak notes] job, url, duration in
            guard let notes else { throw BRRecorderFailure.invalidAudio("本地笔记尚未打开。") }
            try notes.saveRingRecording(job: job, fileURL: url, duration: duration)
        }, exists: { [weak notes] id in notes?.note(id) != nil })
    }

    func configure(save: @escaping (RingTransferJob, URL, Double) throws -> Void, exists: @escaping (UUID) -> Bool) {
        self.save = save; self.exists = exists
    }

    var isBusy: Bool { operation != nil }
    var primaryAction: PrimaryAction {
        guard isConnected else { return binding == nil ? .scan : .reconnect }
        return needsFormatReconciliation ? .reconcileFormat : .controls
    }
    var connectionLabel: String { isConnected ? (isFlashIdeaRecording ? "闪念录制中" : isRecording ? "录音中" : "已连接") : binding == nil ? "未连接" : "已绑定 · 未连接" }

    private func readRecordingState() {
        isFlashIdeaRecording = device.isFlashIdeaRecording()
        isRecording = device.isRecording() || isFlashIdeaRecording
    }

    func foreground() async {
        guard binding != nil, !manuallyDisconnected, !isBusy else { return }
        if isConnected { await refresh() }
        else if let binding { await connect(binding.device) }
    }

    func scan() {
        guard !isBusy, !isConnected, binding == nil, store != nil else { return }
        stopScan(); errorMessage = nil; discovered = []; isScanning = true
        status = "正在寻找附近的 EurekaRing…"
        device.scan()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.stopScan()
            self?.status = "扫描结束。请确认 Ring 已开机并靠近手机。"
        }
    }

    func stopScan() {
        scanTask?.cancel(); scanTask = nil
        if isScanning { device.stopScan() }
        isScanning = false
    }

    func connect(_ selected: BRRecorderDevice) async {
        guard !isBusy, !isConnected, let store else { return }
        if let binding, binding.device.id != selected.id { errorMessage = "请先解绑当前 Ring。"; return }
        let revision = connectionRevision
        stopScan(); operation = .connecting; errorMessage = nil; status = "正在连接并校验设备…"
        defer { finishOperation(revision) }
        do {
            let result = try await device.connect(device: selected, appUUID: binding?.appUUID ?? "")
            try checkConnection(revision, requireReady: false)
            try store.update { $0.binding = result }
            binding = result; isConnected = true; transportIsConnected = true; manuallyDisconnected = false
            flashIdeaSupported = device.flashIdeaSupported
            readRecordingState()
            updateSnapshot()
            if needsFormatReconciliation { status = "请先核对上次格式化的结果。"; return }
            // Never change the device clock in an active recording.
            if !isRecording { try await device.syncTime(); try checkConnection(revision) }
            try await readDeviceStatus(revision)
            if !isRecording { try await readFileList(revision) }
            status = isRecording ? "设备正在录音；结束后会同步到本机。" : "已连接，可开始录音或同步设备文件。"
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = error.localizedDescription; status = isConnected ? "已连接，部分状态读取失败，可刷新重试。" : "连接未完成，请重试。"
        }
    }

    func refresh() async {
        guard isConnected, !isBusy else { return }
        let revision = connectionRevision
        operation = .refreshing; errorMessage = nil
        defer { finishOperation(revision) }
        do {
            readRecordingState()
            try await readDeviceStatus(revision)
            if !isRecording, !needsFormatReconciliation { try await readFileList(revision) }
        } catch { if revision == connectionRevision { errorMessage = error.localizedDescription } }
    }

    private func readDeviceStatus(_ revision: UUID) async throws {
        let level = try await device.battery()
        try checkConnection(revision)
        battery = level
        if !isRecording {
            let capacity = try await device.storageDescription()
            try checkConnection(revision)
            storage = capacity
        }
    }

    private func readFileList(_ revision: UUID) async throws {
        guard let store, let binding else { return }
        let list = try await device.listFiles()
        try checkConnection(revision)
        // A timed-out partial list must not replace known files or imply remote deletion.
        if list.isComplete { files = list.files }
        else {
            var merged: [String: BRRecorderFile] = [:]
            for file in files { merged[file.name] = file }
            for file in list.files { merged[file.name] = file }
            files = Array(merged.values)
        }
        listIsComplete = list.isComplete
        try store.enqueue(list.files, deviceID: binding.device.id)
        updateSnapshot()
        if !list.isComplete { status = "设备返回了部分录音，已保留已知文件；可再次刷新。" }
    }

    func toggleRecording() async {
        guard isConnected, !isBusy, !needsFormatReconciliation else { return }
        readRecordingState()
        guard !isFlashIdeaRecording else { status = "请在 Ring 上结束闪念，随后会自动同步并在本机整理。"; return }
        let revision = connectionRevision
        operation = .recording; errorMessage = nil
        defer { finishOperation(revision) }
        do {
            if isRecording {
                try await device.stopRecording()
                try checkConnection(revision)
                readRecordingState(); syncAfterStop = !isRecording
                status = isRecording ? "设备又开始了录音，结束后再同步。" : "录音已结束，准备同步到本机。"
            } else {
                try await device.syncTime()
                try checkConnection(revision)
                try await device.startRecording()
                try checkConnection(revision)
                readRecordingState()
                status = isRecording ? "Ring 正在录音；可以在设备上或此处结束。" : "设备录音状态已变化，请刷新确认。"
            }
        } catch {
            guard revision == connectionRevision else { return }
            readRecordingState()
            errorMessage = "录音指令未确认：\(error.localizedDescription)"
        }
    }

    func synchronize() async {
        guard isConnected, !isBusy, !isRecording, !device.isRecording(), !needsFormatReconciliation,
              let store, let binding, let save, let exists else { return }
        let revision = connectionRevision
        operation = .syncing; errorMessage = nil; progress = nil
        status = "读取设备录音列表…"; beginBackgroundTime(revision)
        var opened = false
        defer {
            if revision == connectionRevision {
                endBackgroundTime(); conversionTask = nil; progress = nil; activeProgressID = nil; activeTransferName = nil; updateSnapshot(); finishOperation(revision)
            }
        }
        do {
            try await readFileList(revision)
            let jobs = store.pending(deviceID: binding.device.id)
            var savedCount = 0
            var failedCount = 0
            var firstFileError: String?
            for (index, job) in jobs.enumerated() {
                try checkSyncAllowed(binding, revision: revision)
                if exists(job.id) {
                    try store.setStage(job.id, .saved); store.removeArtifacts(job.id); continue
                }
                // Jobs absent from a complete list may represent a physical deletion.
                // A valid local raw copy can still be saved without the device file.
                let directory = try store.directory(job.id)
                let raw = directory.appendingPathComponent("recording.opus")
                let converted = directory.appendingPathComponent("recording.m4a")
                status = "同步录音 \(index + 1)/\(jobs.count)"
                activeProgressID = job.id; progress = nil
                do {
                    if !FileManager.default.fileExists(atPath: raw.path) && !FileManager.default.fileExists(atPath: converted.path) {
                        guard files.contains(where: { $0.name == job.file.name }) else {
                            throw BRRecorderFailure.sdk(code: "FILE_NO_LONGER_AVAILABLE", message: "设备上暂未找到这条录音，请刷新后重试。")
                        }
                        if !opened { try await device.openSync(); try checkSyncAllowed(binding, revision: revision); opened = true }
                        try store.setStage(job.id, .downloading)
                        activeTransferName = job.file.name
                        let downloaded = try await device.transfer(job.file)
                        try checkSyncAllowed(binding, revision: revision)
                        activeTransferName = nil
                        let temporary = directory.appendingPathComponent("recording.download")
                        try? FileManager.default.removeItem(at: temporary)
                        try FileManager.default.copyItem(at: downloaded, to: temporary)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
                        try FileManager.default.moveItem(at: temporary, to: raw)
                        // Only SDK cache copies are removed; device originals are retained.
                        try? FileManager.default.removeItem(at: downloaded)
                    }
                    try store.setStage(job.id, .converting)
                    status = "转换录音 \(index + 1)/\(jobs.count) · 保存在本机"
                    let audio: BRNormalizedAudio
                    if FileManager.default.fileExists(atPath: converted.path) {
                        audio = try validatedAudio(converted)
                    } else {
                        let normalizer = normalize
                        let task = Task {
                            try await normalizer(raw, converted) { [weak self] value in
                                Task { @MainActor [weak self] in
                                    guard self?.connectionRevision == revision, self?.operation == .syncing, self?.activeProgressID == job.id else { return }; self?.progress = value
                                }
                            }
                        }
                        conversionTask = task
                        audio = try await task.value
                        try checkConnection(revision)
                        conversionTask = nil
                    }
                    try checkSyncAllowed(binding, revision: revision)
                    if let expected = job.file.expectedDuration, expected > 2,
                       abs(audio.duration - expected) > max(2, expected * 0.05) {
                        throw BRRecorderFailure.invalidAudio("转换时长与设备记录不符，请重新同步。")
                    }
                    try save(job, audio.url, audio.duration)
                    // A crash after library save is recovered by checking the predetermined note UUID.
                    try store.setStage(job.id, .saved)
                    store.removeArtifacts(job.id); savedCount += 1
                } catch {
                    guard revision == connectionRevision else { return }
                    try? store.setStage(job.id, .failed, error: error.localizedDescription)
                    if case BRRecorderFailure.invalidAudio = error {
                        // Retain one failed raw copy for recovery, and force a fresh transfer on retry.
                        let failed = directory.appendingPathComponent("failed.opus")
                        if FileManager.default.fileExists(atPath: raw.path) {
                            try? FileManager.default.removeItem(at: failed)
                            try? FileManager.default.moveItem(at: raw, to: failed)
                        }
                        try? FileManager.default.removeItem(at: converted)
                        failedCount += 1
                        firstFileError = firstFileError ?? error.localizedDescription
                        continue
                    }
                    throw error
                }
                updateSnapshot()
            }
            if opened { try await device.closeSync(); try checkConnection(revision); opened = false }
            if listIsComplete && failedCount == 0 { try store.update { $0.lastSync[binding.device.id] = .now } }
            if failedCount > 0 {
                errorMessage = "\(failedCount) 条录音需重新同步：\(firstFileError ?? "转换未完成")"
                status = "本次已保存 \(savedCount) 条录音，其余可重试。"
            } else {
                status = listIsComplete ? (savedCount > 0 ? "已保存 \(savedCount) 条录音，正在本机转写。" : "设备录音已同步到本机。") : "本次已同步已取得的录音；列表尚不完整，请再次刷新。"
            }
        } catch {
            guard revision == connectionRevision else { return }
            if opened { try? await device.closeSync() }
            guard revision == connectionRevision else { return }
            errorMessage = "同步未完成：\(error.localizedDescription)"
            status = "已保存的笔记可继续使用；其余录音可重试同步。"
        }
    }

    func disconnect() {
        guard !isBusy else { return }
        manuallyDisconnected = true
        resetDisconnectedState(status: "已断开；绑定和本机历史录音已保留。")
        device.disconnect()
    }

    func unbind() async {
        guard isConnected, !isBusy, !isRecording, !device.isRecording(), let store else { return }
        let revision = connectionRevision
        operation = .unbinding; errorMessage = nil
        defer { finishOperation(revision) }
        do {
            try await device.unbind()
            try checkConnection(revision)
            try store.update { $0.binding = nil }
            binding = nil; manuallyDisconnected = true
            resetDisconnectedState(status: "已解绑；设备录音和本机笔记均已保留。", reportInterruption: false)
            device.disconnect()
        } catch { if revision == connectionRevision { errorMessage = "解绑未确认，绑定信息已保留：\(error.localizedDescription)" } }
    }

    /// Called only by the explicit destructive confirmation in the hardware detail page.
    func format() async {
        guard isConnected, !isBusy, !isRecording, !device.isRecording(), !needsFormatReconciliation, let store, let binding else { return }
        let revision = connectionRevision
        operation = .formatting; errorMessage = nil; status = "正在格式化设备，请保持连接…"
        defer { if revision == connectionRevision { updateSnapshot(); finishOperation(revision) } }
        do {
            try store.update { $0.uncertainFormatDeviceID = binding.device.id }
            updateSnapshot()
            try await device.format()
            try checkConnection(revision)
            try store.update {
                $0.generations[binding.device.id] = UUID()
                $0.uncertainFormatDeviceID = nil
            }
            files = []; listIsComplete = true; status = "设备格式化完成，本机笔记已保留。"
        } catch {
            guard revision == connectionRevision else { return }
            errorMessage = "格式化结果尚未确认：\(error.localizedDescription)"
            status = "请核对设备状态；不会自动再次发送格式化指令。"
        }
    }

    func reconcileFormat() async {
        guard isConnected, !isBusy, !isRecording, !device.isRecording(), needsFormatReconciliation, let store, let binding else { return }
        let revision = connectionRevision
        operation = .refreshing; errorMessage = nil
        defer { if revision == connectionRevision { updateSnapshot(); finishOperation(revision) } }
        do {
            let list = try await device.listFiles()
            try checkConnection(revision)
            guard !isRecording, !device.isRecording() else {
                throw BRRecorderFailure.sdk(code: "DEVICE_RECORDING", message: "请先在 Ring 上结束录音，再核对文件状态。")
            }
            guard list.isComplete else { throw BRRecorderFailure.invalidAudio("设备列表尚未完整，请稍后再次核对。") }
            try store.update {
                if list.files.isEmpty { $0.generations[binding.device.id] = UUID() }
                $0.uncertainFormatDeviceID = nil
            }
            files = list.files; listIsComplete = true
            try store.enqueue(list.files, deviceID: binding.device.id)
            status = list.files.isEmpty ? "设备当前没有录音或闪念，本机笔记已保留。" : "设备仍有录音，可先同步保存；没有重发格式化指令。"
        } catch { if revision == connectionRevision { errorMessage = error.localizedDescription } }
    }

    private func validatedAudio(_ url: URL) throws -> BRNormalizedAudio {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate == 16_000, file.fileFormat.channelCount == 1,
              file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              Double(file.length) / file.processingFormat.sampleRate > 0.1 else {
            throw BRRecorderFailure.invalidAudio("本地转换文件不完整，请重试。")
        }
        return BRNormalizedAudio(url: url, duration: Double(file.length) / file.processingFormat.sampleRate)
    }

    private func checkSyncAllowed(_ expected: BRRecorderBinding, revision: UUID) throws {
        try checkConnection(revision)
        try Task.checkCancellation()
        guard isConnected, binding == expected, !isRecording, !device.isRecording(), !backgroundExpired else {
            throw BRRecorderFailure.sdk(code: "SYNC_INTERRUPTED", message: "连接或录音状态发生变化，请保持 App 在前台后重试。")
        }
    }

    private func checkConnection(_ revision: UUID, requireReady: Bool = true) throws {
        guard revision == connectionRevision, !requireReady || isConnected else {
            throw BRRecorderFailure.sdk(code: "CONNECTION_CHANGED", message: "连接已变化，请重连后重试。")
        }
    }

    /// Release the page immediately on transport loss. Pending SDK completions belong
    /// to the previous connection and cannot modify a subsequent reconnect operation.
    private func resetDisconnectedState(status message: String, reportInterruption: Bool = true) {
        let interrupted = isBusy && reportInterruption
        connectionRevision = UUID(); transportIsConnected = false
        conversionTask?.cancel(); conversionTask = nil
        stopScan(); endBackgroundTime()
        operation = nil; progress = nil; activeProgressID = nil; activeTransferName = nil; syncAfterStop = false
        isConnected = false; isRecording = false; isFlashIdeaRecording = false; flashIdeaSupported = false
        battery = nil; storage = "等待连接"; files = []; listIsComplete = false
        errorMessage = interrupted ? "连接已断开，未完成的操作可在重连后重试。" : nil
        status = message
        updateSnapshot() // Keep binding, notes and uncertain format receipts durable.
    }

    private func finishOperation(_ revision: UUID? = nil) {
        if let revision, revision != connectionRevision { return }
        operation = nil
        if syncAfterStop, isConnected, !isRecording {
            syncAfterStop = false
            let revision = connectionRevision
            Task { [weak self] in
                guard let self, self.connectionRevision == revision else { return }
                await self.synchronize()
            }
        }
    }

    private func updateSnapshot() {
        guard let store, let binding else { pendingCount = 0; lastSync = nil; needsFormatReconciliation = false; return }
        pendingCount = store.pending(deviceID: binding.device.id).count
        lastSync = store.state.lastSync[binding.device.id]
        needsFormatReconciliation = store.state.uncertainFormatDeviceID == binding.device.id
    }

    private func receive(_ event: BRRecorderEvent) {
        switch event {
        case .discovered(let devices): if isScanning { discovered = devices }
        case .connection(let connected):
            // BLE connection precedes the binding handshake; only connect() can publish ready.
            if connected { transportIsConnected = true }
            else if isConnected || transportIsConnected {
                resetDisconnectedState(status: "设备已断开，重连后可确认录音状态并继续同步。")
            }
        case .bluetooth(let state):
            if ["unauthorized", "poweredOff", "unsupported"].contains(state), isConnected || transportIsConnected || isBusy {
                resetDisconnectedState(status: "蓝牙连接不可用，请恢复后重新连接。")
            }
            if state == "unauthorized" { stopScan(); status = "蓝牙权限未开启。"; errorMessage = "请在 iPhone 设置中允许 WiseNote 使用蓝牙。" }
            else if state == "poweredOff" { stopScan(); status = "请开启 iPhone 蓝牙。" }
            else if state == "unsupported" { stopScan(); status = "当前设备不支持蓝牙，请在 iPhone 真机上连接 Ring。" }
            else if state == "poweredOn", isScanning { device.scan() }
        case .recordingStarted(let success):
            guard isConnected else { return }
            readRecordingState()
            isRecording = success || device.isRecording()
            if success {
                status = "Ring 正在录音；结束后会同步到本机。"
                interruptSyncForRecording()
            } else { errorMessage = "设备未能开始录音，请检查剩余空间后重试。" }
        case .recordingStopped:
            guard isConnected else { return }
            readRecordingState()
            syncAfterStop = true
            if !isBusy { finishOperation() }
        case .flashIdeaStarted(let success):
            guard isConnected else { return }
            readRecordingState()
            if success {
                isFlashIdeaRecording = true; isRecording = true
                status = "Ring 正在录制闪念；请在硬件上结束，随后会自动在本机转写、整理。"
                interruptSyncForRecording()
            } else { errorMessage = "设备未能开始闪念，请检查硬件状态后重试。" }
        case let .flashIdeaEnded(file, audioURL):
            guard isConnected else { return }
            // A previous flash may finish its file IO after the next one has started.
            readRecordingState()
            if let file, let audioURL, let store, let binding, !needsFormatReconciliation {
                do { try store.stageFlashAudio(file, from: audioURL, deviceID: binding.device.id) }
                catch { errorMessage = "闪念暂存未完成，可重新从设备同步：\(error.localizedDescription)" }
                updateSnapshot()
            }
            status = isFlashIdeaRecording ? "正在录制下一条闪念，结束后继续同步。" : "闪念已结束，准备在本机转写、整理。"
            syncAfterStop = true
            if !isBusy { finishOperation() }
        case .transferProgress(let received, let name):
            guard operation == .syncing, let name, name == activeTransferName,
                  let size = files.first(where: { $0.name == name })?.byteCount, size > 0 else { return }
            progress = min(1, Double(received) / Double(size))
        }
    }

    private func interruptSyncForRecording() {
        guard operation == .syncing else { return }
        let revision = connectionRevision
        Task { [weak self] in
            guard let self, self.connectionRevision == revision, self.operation == .syncing else { return }
            try? await self.device.closeSync()
        }
    }

    private func beginBackgroundTime(_ revision: UUID) {
        backgroundExpired = false
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RingLocalSync") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionRevision == revision, self.operation == .syncing else { return }
                self.backgroundExpired = true
                self.endBackgroundTime()
                try? await self.device.closeSync()
            }
        }
    }
    private func endBackgroundTime() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
