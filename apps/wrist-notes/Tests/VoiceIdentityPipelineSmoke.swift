import Foundation
import WhisperKit
import SpeakerKit

/// CLI integration fixture: catalogs, models and local synthetic speech supplied explicitly.
@main struct VoiceIdentityPipelineSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { fatalError("usage: pipeline repo-iphone-source speaker-model-root identity-model-root fixture-root output-report") }
        let source = URL(fileURLWithPath: args[1])
        let speakers = SpeakerModelStore(root: URL(fileURLWithPath: args[2]), catalogURL: source.appendingPathComponent("SpeakerModels.json"))
        let identity = VoiceIdentityModelStore(root: URL(fileURLWithPath: args[3]), catalogURL: source.appendingPathComponent("VoiceIdentityModels.json"))
        if ProcessInfo.processInfo.environment["VOICE_PIPELINE_DOWNLOAD_MODELS"] == "1" {
            try await speakers.download { _ in }
            try await identity.download { _ in }
        }
        let service = LocalTranscriptionService(speakers: speakers, identityModels: identity)
        let fixtures = URL(fileURLWithPath: args[4])
        var report: [String] = []
        var failures = 0
        func log(_ message: String) { report.append(message); print(message) }
        let enrollment = fixtures.appendingPathComponent("enroll.wav")
        log("enrollmentSeconds=\(Double(try AudioProcessor.loadAudioAsFloatArray(fromPath: enrollment.path).count)/16000)")
        do {
            let profile = try await service.enrollVoice(fileURL: enrollment)
            log("ENROLL PASS windows=\(profile.embeddings.count) duration=\(profile.recordingDuration)")
            for (name, expectedOwner) in [("same",true),("other",false),("mixed",true)] {
                let file = fixtures.appendingPathComponent(name + ".wav")
                guard FileManager.default.fileExists(atPath: file.path) else { failures += 1; log("MISSING FIXTURE \(name)"); continue }
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
                let duration = Double(samples.count)/16000
                let pieces = stride(from: 0.0, to: duration, by: 2.0).map { TranscriptSegment(start: $0, end: min(duration,$0+2), text: "speech ") }
                let output = try await service.diarizeWithIdentity(fileURL: file, segments: pieces, profile: profile)
                let allIDs = Set(output.segments.compactMap(\.speakerID))
                let actualOwner = !output.ownerSpeakerIDs.isEmpty
                log("\(name) \(actualOwner == expectedOwner ? "PASS" : "FAIL") speakers=\(allIDs.sorted()) owners=\(output.ownerSpeakerIDs.sorted()) identityMessage=\(output.identityMessage ?? "none")")
                if actualOwner != expectedOwner || output.identityMessage != nil || !output.ownerSpeakerIDs.isSubset(of: allIDs) { failures += 1 }
                if name == "mixed" {
                    let specific = output.ownerSpeakerIDs.count == 1 && allIDs.count >= 2
                    log("mixed-specificity=\(specific ? "PASS" : "FAIL")")
                    if !specific { failures += 1 }
                }
                precondition(output.segments.map(\.text).joined() == pieces.map(\.text).joined())
            }
        } catch {
            failures += 1
            log("ENROLL FAIL \(error)")
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: enrollment.path)
            let engine = try await SpeakerKit(PyannoteConfig(modelFolder: speakers.folder.path, download: false, load: false, verbose: false, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
            let diarized = try await engine.diarize(audioArray: samples)
            for segment in diarized.segments {
                log("diagnostic-turn \(segment.startTime)-\(segment.endTime) speaker=\(String(describing: segment.speaker.speakerId))")
            }
            await engine.unloadModels()
            let embedder = VoiceEmbeddingEngine(store: identity)
            var bySpeaker: [Int: [[Float]]] = [:]
            let turns = diarized.segments.compactMap { segment -> SpeakerTurn? in
                guard let speaker = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: speaker)
            }
            func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).reduce(0) { $0 + $1.0*$1.1 } }
            func summarize(_ values: [Float]) -> String {
                let sorted = values.sorted(); guard let minimum = sorted.first, let maximum = sorted.last else { return "none" }
                return "min=\(minimum) median=\(sorted[sorted.count/2]) max=\(maximum) count=\(sorted.count)"
            }
            for speaker in Set(turns.map(\.speaker)).sorted() {
                let ranges = VoiceSpeechSelection.ranges(turns: turns, speaker: speaker, sampleCount: samples.count)
                let windows = VoiceSpeechSelection.windows(samples: samples, ranges: ranges, limit: 12)
                var vectors: [[Float]] = []
                for window in windows { vectors.append(try await embedder.extract(samples: window)) }
                bySpeaker[speaker] = vectors
                var pairs: [Float] = []
                for i in vectors.indices { for j in vectors.indices where j > i { pairs.append(cosine(vectors[i],vectors[j])) } }
                log("speaker=\(speaker) cleanSeconds=\(Double(ranges.reduce(0) { $0 + $1.count })/16000) windows=\(vectors.count) within=\(summarize(pairs))")
            }
            let ids = bySpeaker.keys.sorted()
            for i in ids.indices { for j in ids.indices where j > i {
                let scores = bySpeaker[ids[i], default: []].flatMap { a in bySpeaker[ids[j], default: []].map { cosine(a,$0) } }
                log("between-speaker=\(ids[i]),\(ids[j]) \(summarize(scores))")
            } }
            let allVectors = ids.flatMap { bySpeaker[$0, default: []] }
            do {
                let diagnosticProfile = try VoiceIdentityPolicy.makeProfile(embeddings: allVectors, duration: min(60,Double(samples.count)/16000))
                log("diagnostic-only direct-policy enrollment accepted; production enrollment remains rejected")
                for name in ["same","other","mixed"] {
                    let query = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixtures.appendingPathComponent(name+".wav").path)
                    let windows = VoiceSpeechSelection.windows(samples: query, ranges: [0..<query.count], limit: 6)
                    var vectors: [[Float]] = []
                    for window in windows { vectors.append(try await embedder.extract(samples: window)) }
                    let scores = vectors.flatMap { a in allVectors.map { cosine(a,$0) } }
                    log("direct-policy \(name) match=\(VoiceIdentityPolicy.matches(embeddings: vectors, profile: diagnosticProfile)) cosine=\(summarize(scores))")
                    let duration = Double(query.count)/16000
                    let pieces = stride(from: 0.0, to: duration, by: 2.0).map { TranscriptSegment(start: $0, end: min(duration,$0+2), text: "speech ") }
                    let output = try await service.diarizeWithIdentity(fileURL: fixtures.appendingPathComponent(name+".wav"), segments: pieces, profile: diagnosticProfile)
                    log("diagnostic-profile service \(name) owners=\(output.ownerSpeakerIDs.sorted()) speakers=\(Set(output.segments.compactMap(\.speakerID)).sorted()) message=\(output.identityMessage ?? "none")")
                }
            } catch { log("direct-policy enrollment rejected \(error)") }
            await embedder.unload()
        }
        let mixed = fixtures.appendingPathComponent("mixed.wav")
        if FileManager.default.fileExists(atPath: mixed.path) {
            do { _ = try await service.enrollVoice(fileURL: mixed); failures += 1; log("MIXED ENROLL FAIL accepted two known distinct voices") }
            catch VoiceIdentityError.inconsistentVoice { log("MIXED ENROLL PASS rejected: inconsistentVoice") }
            catch VoiceEnrollmentError.multipleVoices { log("MIXED ENROLL PASS rejected: multipleVoices") }
            catch { failures += 1; log("MIXED ENROLL FAIL unrelated error: \(error)") }
        }
        try report.joined(separator: "\n").write(toFile: args[5], atomically: true, encoding: .utf8)
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) pipeline expectations failed\n".utf8))
            exit(1)
        }
    }
}
