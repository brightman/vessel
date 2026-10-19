import CoreML
import FluidAudio
import Foundation

public struct LocalSpeakerSpan: Sendable {
    public let start: Double
    public let end: Double
    public let speakerID: String
}

public enum LocalDiarization {
    public static let modelLabel = "FluidAudio 0.17.7 · Offline VBx（本机）"
    public static var notices: String {
        ["Attribution.txt", "FluidAudio-Apache-2.0.txt", "Models-NOTICE.md", "Models-README.md", "Models-LICENSE"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Notices") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }

    /// Only model assets are downloaded. The supplied recording is read locally by the offline manager.
    public static func identify(audio: URL, modelsDirectory: URL,
        progress: @escaping @Sendable (String) -> Void) async throws -> [LocalSpeakerSpan] {
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try await OfflineDiarizerModels.load(from: modelsDirectory, configuration: configuration) { update in
            switch update.phase {
            case .listing: progress("正在检查本地模型；首次使用需要下载模型…")
            case .downloading(let completed, let total):
                progress(total > 0 ? "正在准备模型文件 \(completed)/\(total)…" : "正在加载本地模型…")
            case .compiling: progress("正在编译本地说话人模型…")
            }
        }
        try Task.checkCancellation()
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        progress("正在本机区分发言人…")
        let result = try await manager.process(audio) { completed, total in
            progress("正在分析音频片段 \(completed)/\(total)…")
        }
        try Task.checkCancellation()
        // Discard all acoustic embeddings and speaker databases. Only within-recording turns leave this layer.
        return result.segments.map { LocalSpeakerSpan(start: Double($0.startTimeSeconds),
            end: Double($0.endTimeSeconds), speakerID: $0.speakerId) }
    }
}
