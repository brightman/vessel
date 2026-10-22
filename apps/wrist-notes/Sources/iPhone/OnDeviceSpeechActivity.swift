import CoreML
import Foundation

enum SpeechActivityError: Error { case incompatibleModel, invalidOutput }

/// Timing is derived from validated sliding-window sample counts and mask frame counts.
/// All successful covering masks must be inactive with low probabilities to claim noSpeech.
enum PyannoteActivityDecoder {
    static func decode(ids: MLMultiArray, probabilities: MLMultiArray, waveformShape: [Int],
                       inputFrames: Int, validFrames: Int) throws -> [AudioActivityInterval] {
        let shape = ids.shape.map(\.intValue)
        guard shape.count == 3, shape[0] > 0, shape[0] <= 128, shape[1] > 0, shape[1] <= 10_000,
              shape[2] > 0, shape[2] <= 16, probabilities.shape == ids.shape,
              waveformShape.count == 3, waveformShape[0] == shape[0], waveformShape[1] == 1,
              waveformShape[2] > 0, waveformShape[2] <= inputFrames,
              inputFrames > 0, inputFrames <= 480_000, validFrames > 0, validFrames <= inputFrames,
              shape[0] > 1 || waveformShape[2] == inputFrames else { throw SpeechActivityError.invalidOutput }
        let duration = Double(validFrames)/16_000
        let window = Double(waveformShape[2])/16_000
        let stride = shape[0] == 1 ? 0 : Double(inputFrames-waveformShape[2])/16_000/Double(shape[0]-1)
        guard shape[0] == 1 || stride > 0 && stride <= window else { throw SpeechActivityError.invalidOutput }
        var intervals: [AudioActivityInterval] = []
        for index in 0..<shape[0] {
            try Task.checkCancellation()
            for frame in 0..<shape[1] {
                var active = false, uncertain = false
                for speaker in 0..<shape[2] {
                    let key = [index,frame,speaker].map(NSNumber.init(value:))
                    let id = ids[key].doubleValue, probability = probabilities[key].doubleValue
                    guard id.isFinite, id == 0 || id == 1, probability.isFinite, (0...1).contains(probability) else { throw SpeechActivityError.invalidOutput }
                    active = active || id == 1
                    uncertain = uncertain || probability >= 0.2
                }
                let start = Double(index)*stride + Double(frame)*window/Double(shape[1])
                let end = min(duration,Double(index)*stride + Double(frame+1)*window/Double(shape[1]))
                guard end > start else { continue }
                intervals.append(.init(start:start,end:end,kind:active ? .speech : uncertain ? .uncertain : .noSpeech))
            }
        }
        return AudioActivityReconciler.reconcile(start:0,end:duration,detections:intervals,coverage:[.init(start:0,end:duration)],spans:[])
    }
}

struct OnDeviceSpeechActivity {
    let store: SpeakerModelStore
    init(store: SpeakerModelStore = SpeakerModelStore()) { self.store = store }

    /// Must be called under LocalTranscriptionService's shared heavy-work permit.
    /// The Core ML model and each prediction's arrays die before the next stage loads.
    func analyze(_ audio: BoundedAudioFile) throws -> [AudioActivityInterval] {
        try Task.checkCancellation()
        try store.validate()
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf:store.folder.appendingPathComponent(SpeakerModelStore.modelPaths[0]),configuration:configuration)
        guard let input = model.modelDescription.inputDescriptionsByName["waveform"]?.multiArrayConstraint,
              input.shape.map(\.intValue) == [480_000], input.dataType == .float16 || input.dataType == .float32,
              let waveform = model.modelDescription.outputDescriptionsByName["sliding_window_waveform"]?.multiArrayConstraint,
              let masks = model.modelDescription.outputDescriptionsByName["speaker_ids"]?.multiArrayConstraint,
              let probabilities = model.modelDescription.outputDescriptionsByName["speaker_probs"]?.multiArrayConstraint,
              masks.shape == probabilities.shape else { throw SpeechActivityError.incompatibleModel }
        var activities: [AudioActivityInterval] = []
        try audio.forEachBlock(maximumFrames:480_000) { offset, samples in
            let block: [AudioActivityInterval] = try autoreleasepool {
                let array = try MLMultiArray(shape:input.shape,dataType:input.dataType)
                for index in 0..<array.count {
                    let value = index < samples.count ? samples[index] : 0
                    guard value.isFinite else { throw SpeechActivityError.invalidOutput }
                    array[index] = NSNumber(value:value)
                }
                try Task.checkCancellation()
                let result = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["waveform":array]))
                try Task.checkCancellation()
                guard let ids = result.featureValue(for:"speaker_ids")?.multiArrayValue,
                      let probs = result.featureValue(for:"speaker_probs")?.multiArrayValue,
                      let windows = result.featureValue(for:"sliding_window_waveform")?.multiArrayValue,
                      ids.shape == masks.shape, probs.shape == probabilities.shape, windows.shape == waveform.shape else { throw SpeechActivityError.invalidOutput }
                return try PyannoteActivityDecoder.decode(ids:ids,probabilities:probs,waveformShape:windows.shape.map(\.intValue),inputFrames:480_000,validFrames:samples.count)
            }
            activities += block.map { .init(start:$0.start+offset,end:$0.end+offset,kind:$0.kind) }
        }
        return activities
    }
}
