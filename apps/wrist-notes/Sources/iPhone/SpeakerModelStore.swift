import Foundation

struct SpeakerModelStore: Sendable {
    let assets: LocalModelAssetStore
    static let resource = "pyannote"
    static let modelPaths = [
        "speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc",
        "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
        "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
        "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc"
    ]
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WristNotes/SpeakerModels", isDirectory: true),
         catalogURL: URL? = Bundle.main.url(forResource: "SpeakerModels", withExtension: "json"),
         downloadFile: LocalModelAssetStore.Download? = nil) {
        assets = LocalModelAssetStore(root: root, catalogURL: catalogURL,
            requiredPaths: Self.modelPaths.flatMap { model in
                ["coremldata.bin", "model.mil", "weights/weight.bin"].map { model + "/" + $0 }
            }, downloadFile: downloadFile)
    }
    var folder: URL { assets.folder(for: Self.resource) }
    var downloadBytes: Int64 { (try? assets.files(for: Self.resource).reduce(0) { $0 + $1.bytes }) ?? 0 }
    func validate() throws { try assets.validate(Self.resource) }
    func download(progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        try await assets.download(Self.resource, progress: progress)
    }
}
