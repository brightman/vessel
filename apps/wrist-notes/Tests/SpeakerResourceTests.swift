import CryptoKit
import Foundation
import XCTest
@testable import WiseNote

@MainActor final class SpeakerResourceTests: XCTestCase {
    func testExistingDownloadBundlesBothModelsAndResumesOnlyMissingAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let whisperPaths = ["tokenizer.json", "tokenizer_config.json", "AudioEncoder.mlmodelc/weights/weight.bin",
                            "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/weights/weight.bin"]
        let speakerPaths = SpeakerModelStore.modelPaths.flatMap { model in
            ["coremldata.bin", "model.mil", "weights/weight.bin"].map { model + "/" + $0 }
        }
        var payloads: [URL: Data] = [:]
        func manifest(_ paths: [String], name: String) throws -> URL {
            let files = paths.map { path -> WhisperModelFile in
                let data = Data((name + path).utf8)
                let url = URL(string: "https://huggingface.co/fixture/\(name)/\(path)")!
                payloads[url] = data
                return .init(path: path, url: url, bytes: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), gitSHA1: nil)
            }
            let url = root.appendingPathComponent(name + ".json")
            try JSONEncoder().encode([name: files]).write(to: url)
            return url
        }
        let whisperCatalog = try manifest(whisperPaths, name: "tiny")
        let speakerCatalog = try manifest(speakerPaths, name: "pyannote")
        let identityCatalog = try manifest(["wespeaker_v2.mlmodelc/analytics/coremldata.bin", "wespeaker_v2.mlmodelc/coremldata.bin", "wespeaker_v2.mlmodelc/metadata.json", "wespeaker_v2.mlmodelc/model.mil", "wespeaker_v2.mlmodelc/weights/weight.bin"], name: "voice-identity")
        let transport = ModelFixtureTransport(root: root, payloads: payloads)
        let download: LocalModelAssetStore.Download = { request, progress in try await transport.fetch(request, progress: progress) }
        let whisper = WhisperModelStore(root: root.appendingPathComponent("whisper"), catalogURL: whisperCatalog, downloadFile: download)
        let speakers = SpeakerModelStore(root: root.appendingPathComponent("speakers"), catalogURL: speakerCatalog, downloadFile: download)
        let identity = VoiceIdentityModelStore(root: root.appendingPathComponent("identity"), catalogURL: identityCatalog, downloadFile: download)
        let client = TranscriptionResourceClient.live(store: whisper, speakers: speakers, identity: identity)
        let config = TranscriptionConfiguration(engine: .whisper, whisperSize: .tiny)
        var status = try await client.status(config)
        XCTAssertEqual(status, .missing)
        do { try await client.download(config) { _ in }; XCTFail("Expected first speaker download to fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertTrue(whisper.installed(.tiny), "Completed ASR model must survive a speaker download failure")
        status = try await client.status(config)
        XCTAssertEqual(status, .missing, "Whisper alone cannot mark the bundle ready")
        let firstASRRequests = await transport.whisperRequests
        do { try await client.download(config) { _ in }; XCTFail("Expected identity download to fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        try speakers.validate()
        status = try await client.status(config)
        XCTAssertEqual(status, .missing, "Diarization alone cannot mark identity bundle ready")
        try await client.download(config) { _ in }
        status = try await client.status(config)
        XCTAssertEqual(status, .ready)
        try speakers.validate()
        try identity.validate()
        let finalASRRequests = await transport.whisperRequests
        XCTAssertEqual(firstASRRequests, finalASRRequests, "Retry must not fetch existing Whisper assets")
    }
}

private actor ModelFixtureTransport {
    let root: URL
    let payloads: [URL: Data]
    var failSpeakerOnce = true
    var failIdentityOnce = true
    private(set) var whisperRequests = 0
    init(root: URL, payloads: [URL: Data]) { self.root = root; self.payloads = payloads }
    func fetch(_ request: URLRequest, progress: @escaping @Sendable (Int64) -> Void) throws -> (URL, URLResponse) {
        let url = request.url!
        if url.path.contains("/pyannote/"), failSpeakerOnce {
            failSpeakerOnce = false
            throw URLError(.networkConnectionLost)
        }
        if url.path.contains("/tiny/") { whisperRequests += 1 }
        if url.path.contains("/voice-identity/"), failIdentityOnce {
            failIdentityOnce = false
            throw URLError(.networkConnectionLost)
        }
        let data = try XCTUnwrap(payloads[url])
        let file = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        progress(Int64(data.count))
        return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
