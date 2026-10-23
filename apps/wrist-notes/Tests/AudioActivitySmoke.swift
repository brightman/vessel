import AVFAudio
import Darwin
import Foundation
import CoreML

@main struct AudioActivitySmoke {
    static func main() throws {
        setbuf(stdout,nil)
        // Dropping explicit coverage or letting failed intervals count as silence must fail.
        let analysis = AudioActivityReconciler.reconcile(start: 0,end: 12,
            detections: [.init(start:0,end:4,kind:.noSpeech),.init(start:6,end:12,kind:.noSpeech),.init(start:7,end:8,kind:.speech)],
            coverage: [.init(start:0,end:4),.init(start:6,end:12)],
            spans:[.init(start:9,end:10,text:"again")])
        precondition(analysis == [.init(start:0,end:4,kind:.noSpeech),.init(start:4,end:6,kind:.uncertain),.init(start:6,end:7,kind:.noSpeech),.init(start:7,end:8,kind:.speech),.init(start:8,end:9,kind:.noSpeech),.init(start:9,end:10,kind:.uncertain),.init(start:10,end:12,kind:.noSpeech)])
        let overlap = AudioActivityReconciler.reconcile(start:0,end:3,detections:[.init(start:0,end:3,kind:.noSpeech),.init(start:1,end:2,kind:.uncertain)],coverage:[.init(start:0,end:3)],spans:[])
        precondition(overlap == [.init(start:0,end:1,kind:.noSpeech),.init(start:1,end:2,kind:.uncertain),.init(start:2,end:3,kind:.noSpeech)])
        let ownershipRange = try AudioSourceRange(range:.init(chunkID:UUID(),url:URL(fileURLWithPath:"/unused"),
            startFrame:0,endFrame:48_000,sampleRate:16_000,sessionStartOffset:0,discontinuityBefore:nil),contentHash:String(repeating:"d",count:64))
        let ownership = AudioProcessingWindow(id:"ownership",sourceID:.init(kind:.legacyNote,id:UUID()),configurationKey:"test",coreStart:0,coreEnd:3,ranges:[ownershipRange])
        let repeats = try AudioWindowPlanner.ownedSpans([.init(start:0,end:1,text:"again"),.init(start:2,end:3,text:"again")],window:ownership)
        precondition(repeats.count == 2 && repeats[0].text == repeats[1].text,"equal utterances at different source times were deduplicated")
        let retained = [AudioTranscriptSpan(start:40,end:41,text:"hello"),
                        AudioTranscriptSpan(start:41,end:42,text:" world"),
                        AudioTranscriptSpan(start:42.123456789,end:42.543210987,text:"again")]
        let updates = try AudioSpeakerMapping.annotating(retained,speakerIDs:["speaker-1","speaker-1",nil])
        precondition(updates.count == retained.count)
        for (original, updated) in zip(retained,updates) {
            precondition(original.start == updated.start && original.end == updated.end && original.text == updated.text,
                         "speaker annotations must preserve exact original source rows")
        }
        precondition(updates[0].speakerID == "speaker-1" && updates[1].speakerID == "speaker-1" && updates[2].speakerID == nil)
        precondition(retained.allSatisfy { $0.speakerID == nil },"annotation mutated retained evidence")
        do { _ = try AudioSpeakerMapping.annotating(retained,speakerIDs:["speaker-1"]); fatalError("accepted coalesced annotations") }
        catch AudioProcessingError.invalidInput { }
        let model = AudioSpeakerFeature(localSpeakerID:"speaker-1",modelVersion:"m1",vector:[1,0])
        let sameName = AudioSpeakerFeature(localSpeakerID:"speaker-1",modelVersion:"m1",vector:[0,1])
        precondition(AudioSpeakerMapping.match(model,candidates:["other":sameName]) == nil,"local IDs must not merge")
        precondition(AudioSpeakerMapping.match(model,candidates:["owner":model]) == "owner")
        precondition(AudioSpeakerMapping.match(model,candidates:["a":model,"b":model]) == nil,"ambiguous runner-up must abstain")
        precondition(AudioSpeakerMapping.match(model,candidates:["a":.init(localSpeakerID:"x",modelVersion:"m2",vector:[1,0])]) == nil)
        precondition(AudioSpeakerMapping.match(model,candidates:["a":.init(localSpeakerID:"x",modelVersion:"m1",vector:[1])]) == nil)
        precondition(AudioSpeakerMapping.match(.init(localSpeakerID:"x",modelVersion:"m1",vector:[.nan,0]),candidates:["a":model]) == nil)
        precondition(!AudioSpeakerMapping.permitsAnalysis(sourceDuration:nil))
        precondition(!AudioSpeakerMapping.permitsAnalysis(sourceDuration:1800.1))
        precondition(AudioSpeakerMapping.permitsAnalysis(sourceDuration:1800))
        // Shape-derived timing: 6-second input, two 4-second overlapping windows, two frames.
        let ids = try MLMultiArray(shape:[2,2,1],dataType:.float32)
        let probs = try MLMultiArray(shape:[2,2,1],dataType:.float32)
        for i in 0..<4 { ids[i] = 0; probs[i] = 0 }
        ids[1] = 1; probs[1] = 0.9
        let masks = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:96_000)
        precondition(masks == [.init(start:0,end:2,kind:.noSpeech),.init(start:2,end:4,kind:.speech),.init(start:4,end:6,kind:.noSpeech)],"overlapping active mask must win")
        ids[1] = 0; probs[1] = 0.4
        let ambiguous = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:80_000)
        precondition(ambiguous == [.init(start:0,end:2,kind:.noSpeech),.init(start:2,end:4,kind:.uncertain),.init(start:4,end:5,kind:.noSpeech)])
        // Real Core ML FP16 output from long AAC capture can be one ULP above one.
        // It is strong activity evidence, never silence or a reason to drop a whole window.
        probs[1] = NSNumber(value:1.0009765625)
        let rounded = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:80_000)
        precondition(rounded == ambiguous,"FP16 overshoot must remain uncertain without an active mask")
        ids[1] = 1
        let roundedSpeech = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:80_000)
        precondition(roundedSpeech == [.init(start:0,end:2,kind:.noSpeech),.init(start:2,end:4,kind:.speech),.init(start:4,end:5,kind:.noSpeech)],"FP16 overshoot must retain active speech")
        for invalid in [-0.0001,1.001953125,Double.infinity,Double.nan] {
            probs[1] = NSNumber(value:invalid)
            do { _ = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:96_000); fatalError("invalid probability accepted") }
            catch SpeechActivityError.invalidOutput { }
        }
        ids[1] = 0; probs[1] = 0.4
        probs[0] = NSNumber(value:Double.nan)
        do { _ = try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:[2,1,64_000],inputFrames:96_000,validFrames:96_000); fatalError("nonfinite output accepted") } catch { }
        if let root = ProcessInfo.processInfo.environment["BOUNDED_VAD_MODEL_ROOT"] {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vad-adapter-\(UUID())")
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:temporary) }
            let store = SpeakerModelStore(root:URL(fileURLWithPath:root),catalogURL:URL(fileURLWithPath:"Sources/iPhone/SpeakerModels.json"))
            // Verifies every installed catalog file before Core ML is loaded. No download path.
            try store.validate()
            for name in ["silence","tone","syntheticSpeech"] {
                let source = temporary.appendingPathComponent(name+".caf")
                let format = AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1)!
                let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:480_000)!
                buffer.frameLength = 480_000
                for i in 0..<480_000 { buffer.floatChannelData![0][i] = name == "tone" ? Float(0.15*sin(Double(i)*2 * .pi*440/16_000)) : 0 }
                if name == "syntheticSpeech" {
                    guard let path = ProcessInfo.processInfo.environment["BOUNDED_VAD_SYNTHETIC_F32"] else { fatalError("generated speech fixture path required") }
                    let data = try Data(contentsOf:URL(fileURLWithPath:path))
                    precondition(data.count > 0 && data.count <= 480_000*4 && data.count%4 == 0)
                    data.withUnsafeBytes { bytes in
                        for i in 0..<(bytes.count/4) { buffer.floatChannelData![0][i] = bytes.loadUnaligned(fromByteOffset:i*4,as:Float.self) }
                    }
                }
                do { let file = try AVAudioFile(forWriting:source,settings:format.settings); try file.write(from:buffer) }
                let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:source,startFrame:0,endFrame:480_000,sampleRate:16_000,sessionStartOffset:100,discontinuityBefore:nil),contentHash:String(repeating:"b",count:64))
                let window = AudioProcessingWindow(id:name,sourceID:.init(kind:.legacyNote,id:UUID()),configurationKey:"vad",coreStart:100,coreEnd:130,ranges:[range])
                let audio = try BoundedAudioReader(temporaryRoot:temporary).materialize(window)
                defer { audio.cleanup() }
                let intervals = try OnDeviceSpeechActivity(store:store).analyze(audio)
                precondition(intervals.first?.start == 0 && intervals.last?.end == 30)
                for index in intervals.indices.dropFirst() { precondition(abs(intervals[index-1].end-intervals[index].start)<1e-7) }
                let speech = intervals.filter { $0.kind == .speech }.reduce(0.0) { $0+$1.end-$1.start }
                let silence = intervals.filter { $0.kind == .noSpeech }.reduce(0.0) { $0+$1.end-$1.start }
                if name == "syntheticSpeech" { precondition(speech > 10,"real model did not detect generated speech") }
                else { precondition(speech == 0 && silence == 30,"real model did not confirm generated inactive audio") }
                precondition(audio.sourceRanges(start:0,end:30) == [.init(start:100,end:130)])
                print("Actual cached Pyannote adapter",name,"speech seconds",speech,"noSpeech seconds",silence,"complete interval coverage",intervals.count)
            }
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            print("Actual Mac model process peak RSS bytes:",usage.ru_maxrss,"(not iPhone/device memory evidence)")
        }
        print("Activity/mapping: passed (coverage gaps, transcript conflict, overlapping masks, shape timing, nonfinite, model/dimension/margin/long-source guards)")
    }
}
