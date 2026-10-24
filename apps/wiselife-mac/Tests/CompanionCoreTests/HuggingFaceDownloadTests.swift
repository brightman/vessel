import XCTest
@testable import CompanionCore

final class HuggingFaceDownloadTests: XCTestCase {
    /// Opt-in network check: model card + LFS tokenizer exercise Hub and CDN
    /// redirects without downloading any language-model weights.
    func testPinnedMetadataAndTokenizerDownloadFromRealHuggingFace() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISELIFE_HF_DOWNLOAD_SMOKE"] == "1", "Set WISELIFE_HF_DOWNLOAD_SMOKE=1 for the real Hub/CDN smoke test")
        let model = try XCTUnwrap(CatalogModel.bundled().first { $0.id == ModelRecommendation.balanced })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["README.md", "tokenizer.json"] {
            let file = try XCTUnwrap(model.files.first { $0.name == name })
            let destination = root.appendingPathComponent(file.name)
            let url = try XCTUnwrap(URL(string: "https://huggingface.co/\(model.id)/resolve/\(model.revision)/\(file.name)"))
            try await HubModelFetcher().fetch(url, to: destination, expectedBytes: file.bytes) { _ in }
            try ModelStore.verify(destination, file: file)
        }
    }
}
