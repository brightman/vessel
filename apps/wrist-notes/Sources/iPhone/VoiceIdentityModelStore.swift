import Foundation

struct VoiceIdentityModelStore: Sendable {
    private let assets: LocalModelAssetStore
    private static let key = "voice-identity"
    static let modelID = VoiceIdentityPolicy.modelID
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WristNotes/Models", isDirectory: true),
         catalogURL: URL? = Bundle.main.url(forResource: "VoiceIdentityModels", withExtension: "json"),
         downloadFile: LocalModelAssetStore.Download? = nil) {
        assets = LocalModelAssetStore(root: root, catalogURL: catalogURL, requiredPaths: [
            "wespeaker_v2.mlmodelc/analytics/coremldata.bin", "wespeaker_v2.mlmodelc/coremldata.bin",
            "wespeaker_v2.mlmodelc/metadata.json", "wespeaker_v2.mlmodelc/model.mil",
            "wespeaker_v2.mlmodelc/weights/weight.bin"], downloadFile: downloadFile)
    }
    var folder: URL { assets.folder(for: Self.key).appendingPathComponent("wespeaker_v2.mlmodelc", isDirectory: true) }
    var downloadBytes: Int64 { ((try? assets.files(for: Self.key)) ?? []).reduce(0) { $0 + $1.bytes } }
    var installed: Bool { assets.installed(Self.key) }
    func validate() throws { try assets.validate(Self.key) }
    func download(progress: @escaping @Sendable (SpeechDownloadProgress) -> Void) async throws {
        try await assets.download(Self.key, progress: progress)
    }
}
