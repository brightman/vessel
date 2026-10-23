import AVFAudio
import Foundation

@main struct CaptureSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatchRecordingSessionStore(root: root)
        var sealed: [RecordingChunkDescriptor] = []
        let writer = try RecordingChunkWriter(sessionID: UUID(), root: root, onSeal: { chunk, url in
            try store.seal(chunk, file: url); sealed.append(chunk)
        })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        // 1,200 s + 17 samples crosses two exact 600 s boundaries. Numbered tones
        // change at boundaries, allowing time-localized lossy-decoder checks.
        let total = 19_200_017
        var written = 0
        while written < total {
            let take = min(4096, total - written)
            pcm.frameLength = AVAudioFrameCount(take)
            for i in 0..<take {
                let frame = written + i
                let frequency: Double
                if (9_595_904..<9_600_000).contains(frame) { frequency = 900 }
                else if (9_600_000..<9_604_096).contains(frame) { frequency = 1300 }
                else { frequency = frame < 9_600_000 ? 300 : 700 }
                pcm.floatChannelData![0][i] = Float(sin(Double(frame) * 2 * .pi * frequency / 16000)) * 0.2
            }
            try writer.append(pcm); written += take
            if written >= 9_600_000 && written - take < 9_600_000 {
                precondition(sealed.count == 1 && sealed[0].frameCount == 9_600_000,
                    "first ten-minute file must seal while recording continues, before finish")
            }
        }
        try writer.finish(); try writer.finish()
        precondition(sealed.map(\.frameCount) == [9_600_000, 9_600_000, 17], "no lost or duplicated effective frames at rotations")
        precondition(sealed.map(\.sessionStartOffset) == [0, 600, 1200])
        precondition(writer.effectiveFrames == 19_200_017)
        for (index, chunk) in sealed.enumerated() {
            _ = try RecordingAudioFile.validate(chunk, at: store.audioURL(for: chunk))
            if index < 2 {
                let file = try AVAudioFile(forReading: store.audioURL(for: chunk))
                file.framePosition = 16000
                let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
                try file.read(into: decoded)
                var crossings = 0
                for i in 1..<Int(decoded.frameLength) where decoded.floatChannelData![0][i-1] < 0 && decoded.floatChannelData![0][i] >= 0 { crossings += 1 }
                let expected = index == 0 ? 300 : 700
                precondition(abs(crossings - expected) < 3, "boundary tone belongs in correct output chunk")
            }
        }
        for (ordinal, position, expectedCrossings) in [(0, Int64(9_595_904), 230), (1, Int64(0), 333)] {
            let file = try AVAudioFile(forReading: store.audioURL(for: sealed[ordinal]))
            file.framePosition = position
            let marker = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: marker)
            var crossings = 0
            for frame in 1..<Int(marker.frameLength) where marker.floatChannelData![0][frame-1] < 0 && marker.floatChannelData![0][frame] >= 0 { crossings += 1 }
            precondition(abs(crossings - expectedCrossings) <= 6, "marker immediately adjacent to rotation must remain on its own side")
        }
        do { try writer.append(pcm); fatalError("append after finish must fail") } catch {}
        // A real filesystem failure must propagate, retaining existing chunks.
        let blocked = root.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        do { _ = try RecordingChunkWriter(sessionID: UUID(), root: blocked, onSeal: { _, _ in }); fatalError("write failure must propagate") } catch {}
        // Capacity policy uses real writer/sealing; only the OS capacity reading
        // is injected. Stop must preserve previously unacknowledged originals.
        let beforeStorageChunks = store.chunks
        let refusedRoot = root.appendingPathComponent("refused-storage")
        do {
            _ = try RecordingChunkWriter(sessionID: UUID(), root: refusedRoot,
                capacityReader: { _ in 16 * 1024 * 1024 }, onSeal: { _, _ in })
            fatalError("start at sealing margin must refuse")
        } catch SegmentedAudioCapture.Failure.lowStorage {}
        precondition(!FileManager.default.fileExists(atPath: refusedRoot.path))
        var capacityChecks = 0
        var warningCount = 0
        let lowWriter = try RecordingChunkWriter(sessionID: UUID(), root: root.appendingPathComponent("low-storage"),
            capacityReader: { _ in
                capacityChecks += 1
                return Int64(([64, 24, 24, 8][min(capacityChecks - 1, 3)]) * 1024 * 1024)
            }, onStorageWarning: { warningCount += 1 }, onSeal: { chunk, url in try store.seal(chunk, file: url) })
        pcm.frameLength = 4096
        do {
            for _ in 0..<20 { try lowWriter.append(pcm) }
            fatalError("capacity crossing stop margin must interrupt")
        } catch SegmentedAudioCapture.Failure.lowStorage {}
        try lowWriter.finish()
        precondition(warningCount == 1, "low-storage warning must be emitted once per capture")
        precondition(lowWriter.effectiveFrames == 49152, "stop must preserve all audio written before capacity fell below margin")
        precondition(store.chunks.count == beforeStorageChunks.count + 1)
        for original in beforeStorageChunks { _ = try RecordingAudioFile.validate(original, at: store.audioURL(for: original)) }
        let failureID = UUID()
        let failureRoot = root.appendingPathComponent("write-failure")
        let failingWriter = try RecordingChunkWriter(sessionID: failureID, root: failureRoot,
            capacityReader: { _ in 64 * 1024 * 1024 }, onSeal: { chunk, url in try store.seal(chunk, file: url) })
        try failingWriter.append(pcm)
        let conflictingMetadata = root.appendingPathComponent(failureID.uuidString).appendingPathComponent("\(failureID.uuidString)_0000.m4a.seal.json")
        try FileManager.default.createDirectory(at: conflictingMetadata, withIntermediateDirectories: true)
        do { try failingWriter.finish(); fatalError("real seal write failure must propagate") } catch {}
        let retainedFailure = failureRoot.appendingPathComponent("\(failureID.uuidString)_0000.partial.m4a")
        precondition(FileManager.default.fileExists(atPath: retainedFailure.path))
        precondition(FileManager.default.fileExists(atPath: retainedFailure.appendingPathExtension("capture.json").path))
        // Pool saturation must reject promptly without reusing a worker-owned slot.
        let pool = RecordingPCMBufferPool(format: format, count: 2, frameCapacity: 4096)
        pcm.frameLength = 4096
        precondition(pool.offer(pcm)); precondition(pool.offer(pcm)); precondition(!pool.offer(pcm))
        let held = pool.take()!
        precondition(!pool.offer(pcm), "in-flight worker buffer cannot be overwritten")
        pool.release(held.0); precondition(pool.offer(pcm))
        // Real concurrent producer/consumer: each submitted numbered sample must
        // arrive in order; retained slots cannot be reused before consumer release.
        let ring = RecordingPCMBufferPool(format: format, count: 4, frameCapacity: 64)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        input.frameLength = 64
        let finishedConsumer = DispatchGroup()
        finishedConsumer.enter()
        DispatchQueue.global().async {
            var expected = 0
            while expected < 320000 {
                if let (slot, buffer) = ring.take() {
                    precondition(buffer.frameLength == 64)
                    for index in 0..<64 {
                        precondition(buffer.floatChannelData![0][index] == Float(expected), "ring lost, reordered or reused a sample")
                        expected += 1
                    }
                    ring.release(slot)
                } else { Thread.sleep(forTimeInterval: 0.00001) }
            }
            finishedConsumer.leave()
        }
        for batch in 0..<5000 {
            for index in 0..<64 { input.floatChannelData![0][index] = Float(batch * 64 + index) }
            while !ring.offer(input) { try await Task.sleep(nanoseconds: 10_000) }
        }
        precondition(finishedConsumer.wait(timeout: .now() + 10) == .success)
        precondition(ring.take() == nil)
        // Real serial pipeline converts 48k native input without activating a mic.
        let native = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pipelineRoot = root.appendingPathComponent(UUID().uuidString)
        let pipelineStore = WatchRecordingSessionStore(root: root.appendingPathComponent("converted"))
        let pipeline = try RecordingCapturePipeline(format: native, sessionID: UUID(), root: pipelineRoot,
            origin: .init(device: "synthetic", deviceID: "fixture", fileName: "tone", recordingTimeIsEstimated: false),
            onSeal: { chunk, url in try pipelineStore.seal(chunk, file: url) }, onFailure: { _ in })
        let nativePCM = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 2048)!
        var remaining = 48000
        while remaining > 0 {
            nativePCM.frameLength = AVAudioFrameCount(min(2048, remaining))
            for i in 0..<Int(nativePCM.frameLength) { nativePCM.floatChannelData![0][i] = 0.1 }
            pipeline.submit(nativePCM); remaining -= Int(nativePCM.frameLength)
        }
        async let finishA: Void = pipeline.finish()
        async let finishB: Void = pipeline.finish()
        try await finishA; try await finishB
        precondition(pipelineStore.chunks.map(\.frameCount) == [16000], "conversion flush must retain exact effective duration: \(pipelineStore.chunks.map(\.frameCount))")
        // Hold the actual 600 s seal callback while stop enters the same pipeline.
        let boundaryEntered = DispatchSemaphore(value: 0)
        let releaseBoundary = DispatchSemaphore(value: 0)
        let boundaryStore = WatchRecordingSessionStore(root: root.appendingPathComponent("boundary-store"))
        let boundaryPipeline = try RecordingCapturePipeline(format: format, sessionID: UUID(), root: root.appendingPathComponent("boundary-capture"),
            origin: .init(device: "synthetic", deviceID: "fixture", fileName: "tone", recordingTimeIsEstimated: false),
            capacityReader: { _ in 64 * 1024 * 1024 }, onSeal: { chunk, url in
                if chunk.ordinal == 0 {
                    boundaryEntered.signal()
                    precondition(releaseBoundary.wait(timeout: .now() + 10) == .success)
                }
                try boundaryStore.seal(chunk, file: url)
            }, onFailure: { _ in })
        var boundarySubmitted = 0
        while boundarySubmitted < 9_600_128 {
            pcm.frameLength = AVAudioFrameCount(min(4096, 9_600_128 - boundarySubmitted))
            boundaryPipeline.submit(pcm); boundarySubmitted += Int(pcm.frameLength)
            if boundarySubmitted < 9_600_000 {
                let deadline = Date().addingTimeInterval(10)
                while boundaryPipeline.sampledDuration * 16000 + 0.5 < Double(boundarySubmitted) {
                    precondition(Date() < deadline, "boundary pipeline must keep making progress")
                    await Task.yield()
                }
            }
        }
        precondition(boundaryEntered.wait(timeout: .now() + 10) == .success)
        let (stopEnqueued, stopSignal) = AsyncStream<Void>.makeStream()
        let boundaryStop = Task {
            try await boundaryPipeline.finish(onEnqueued: { stopSignal.yield(()); stopSignal.finish() })
        }
        var stopEvents = stopEnqueued.makeAsyncIterator()
        let enqueued: Void? = await stopEvents.next()
        precondition(enqueued != nil, "finish must enqueue its stop while the boundary seal remains held")
        releaseBoundary.signal()
        try await boundaryStop.value
        precondition(boundaryStore.chunks.map(\.frameCount) == [9_600_000, 128], "stop racing rotation must seal boundary and nonempty tail exactly once")
        let interrupted = try RecordingCapturePipeline(format: format, sessionID: UUID(), root: root.appendingPathComponent("interrupted"),
            origin: .init(device: "synthetic", deviceID: "fixture", fileName: "tone", recordingTimeIsEstimated: false),
            onSeal: { _, _ in }, onFailure: { _ in })
        interrupted.interrupt(SegmentedAudioCapture.Failure.routeChanged)
        do { try await interrupted.finish(); fatalError("route change must remain interrupted at stop") } catch {}
        let overloaded = try RecordingCapturePipeline(format: format, sessionID: UUID(), root: root.appendingPathComponent("overloaded"),
            origin: .init(device: "synthetic", deviceID: "fixture", fileName: "tone", recordingTimeIsEstimated: false),
            onSeal: { _, _ in }, onFailure: { _ in })
        for _ in 0..<1000 { overloaded.submit(pcm) }
        do { try await overloaded.finish(); fatalError("overflow must surface at stop") } catch {}
        print("Segmented capture synthetic smoke passed: 19200017 effective frames, three chunks")
    }
}
