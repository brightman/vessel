import CoreML
import Foundation

/// Local inference only. Callers supply clean, non-overlapping 16 kHz mono speech.
actor VoiceEmbeddingEngine {
    private let store: VoiceIdentityModelStore
    private var model: MLModel?
    init(store: VoiceIdentityModelStore = VoiceIdentityModelStore()) { self.store = store }
    func unload() { model = nil }
    func extract(samples: [Float]) throws -> [Float] {
        try Task.checkCancellation()
        guard (32_000...160_000).contains(samples.count), samples.allSatisfy(\.isFinite),
              samples.allSatisfy({ abs($0) <= 1 }),
              samples.reduce(Double(0), { $0 + Double($1) * Double($1) }) / Double(samples.count) > 1e-8 else {
            throw VoiceIdentityError.invalidAudio
        }
        if model == nil {
            try store.validate()
            let configuration = MLModelConfiguration(); configuration.computeUnits = .all
            let loaded = try MLModel(contentsOf: store.folder, configuration: configuration)
            func shape(_ description: MLFeatureDescription?, _ expected: [Int]) -> Bool {
                guard let constraint = description?.multiArrayConstraint else { return false }
                return constraint.dataType == .float32 && constraint.shape.map(\.intValue) == expected
            }
            guard shape(loaded.modelDescription.inputDescriptionsByName["waveform"], [3,160_000]),
                  shape(loaded.modelDescription.inputDescriptionsByName["mask"], [3,589]),
                  shape(loaded.modelDescription.outputDescriptionsByName["embedding"], [3,256]) else {
                throw VoiceIdentityError.incompatibleModel
            }
            model = loaded
        }
        guard let model else { throw VoiceIdentityError.incompatibleModel }
        let waveform = try MLMultiArray(shape: [3,160_000], dataType: .float32)
        let mask = try MLMultiArray(shape: [3,589], dataType: .float32)
        // Match the upstream extractor's repeat padding. Only batch row zero is active;
        // every padded frame contains solo speech, so its full activity mask is one.
        for row in 0..<3 {
            for column in 0..<160_000 { waveform[[row as NSNumber,column as NSNumber]] = NSNumber(value: row == 0 ? samples[column % samples.count] : 0) }
            for column in 0..<589 { mask[[row as NSNumber,column as NSNumber]] = NSNumber(value: row == 0 ? 1 : 0) }
        }
        try Task.checkCancellation()
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["waveform": waveform, "mask": mask]))
        guard let output = result.featureValue(for: "embedding")?.multiArrayValue,
              output.shape.map(\.intValue) == [3,256] else { throw VoiceIdentityError.incompatibleModel }
        let vector = (0..<256).map { output[[0, NSNumber(value: $0)]].floatValue }
        try Task.checkCancellation()
        return try VoiceIdentityPolicy.normalized(vector)
    }
}
