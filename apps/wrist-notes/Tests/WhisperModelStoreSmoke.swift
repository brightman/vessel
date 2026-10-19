import CryptoKit
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

// Replace only the network boundary: hashing, persistence, cancellation, staging,
// promotion and coordination all run through the production store.
private actor FixtureDownload {
    let directory: URL
    let data: [String: Data]
    var attempts: [String: Int] = [:]
    var failOnce: String?
    var holdOnce: String?
    var corruptOnce: String?
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private var active = 0
    private(set) var maximumActive = 0

    init(directory: URL, data: [String: Data], failOnce: String? = nil, holdOnce: String? = nil, corruptOnce: String? = nil) {
        self.directory = directory; self.data = data
        self.failOnce = failOnce; self.holdOnce = holdOnce; self.corruptOnce = corruptOnce
    }
    func download(_ request: URLRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        let path = request.url!.path
        attempts[path, default: 0] += 1
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if holdOnce == path {
            holdOnce = nil; held = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        try Task.checkCancellation()
        if failOnce == path {
            failOnce = nil
            throw URLError(.networkConnectionLost)
        }
        guard var bytes = data[path] else { throw TestFailure(description: "unexpected fixture URL") }
        if corruptOnce == path { corruptOnce = nil; bytes = Data(repeating: 0, count: bytes.count) }
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: temporary)
        progress(Int64(bytes.count))
        return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { release?.resume(); release = nil }
    func count(_ path: String) -> Int { attempts[path, default: 0] }
    func totalCount() -> Int { attempts.values.reduce(0, +) }
}

private struct Fixture {
    let root: URL
    let catalog: URL
    let transport: FixtureDownload
    let files: [WhisperModelFile]
    static let paths = ["tokenizer.json", "tokenizer_config.json", "AudioEncoder.mlmodelc/weights/weight.bin",
                        "TextDecoder.mlmodelc/weights/weight.bin", "MelSpectrogram.mlmodelc/weights/weight.bin"]
    init(fail: Bool = false, hold: Bool = false, corrupt: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-store-smoke-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        catalog = root.appendingPathComponent("catalog.json")
        var payload: [String: Data] = [:]
        files = Self.paths.enumerated().map { index, path in
            let data = Data("verified fixture \(index) for \(path)".utf8)
            payload["/" + path] = data
            let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let gitData = Data("blob \(data.count)\0".utf8) + data
            let sha1 = Insecure.SHA1.hash(data: gitData).map { String(format: "%02x", $0) }.joined()
            return WhisperModelFile(path: path, url: URL(string: "https://huggingface.co/" + path)!, bytes: Int64(data.count),
                                    sha256: index == 1 ? nil : sha256, gitSHA1: sha1)
        }
        try JSONEncoder().encode(["tiny": files, "base": files]).write(to: catalog)
        transport = FixtureDownload(directory: root, data: payload,
            failOnce: fail ? "/" + Self.paths[1] : nil, holdOnce: hold ? "/" + Self.paths[1] : nil,
            corruptOnce: corrupt ? "/" + Self.paths[0] : nil)
    }
    func store() -> WhisperModelStore {
        WhisperModelStore(root: root.appendingPathComponent("models"), catalogURL: catalog,
                          downloadFile: { [transport] request, progress in try await transport.download(request, progress: progress) })
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func assertNoStaging() throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: store().root.path)
        try expect(!entries.contains { $0.hasPrefix(".download-") || $0.hasPrefix(".assembly-") }, "assembly staging must be cleaned")
    }
}

@main struct WhisperModelStoreSmoke {
    static func main() async throws {
        try await retryAfterFailure()
        try await retryAfterCancellation()
        try await concurrentInstalls()
        try await corruptCacheIsRefetched()
        try await badDownloadNeverEntersCache()
        try await incompleteOrCorruptInstallationIsRejected()
        try await catalogRetainsNetworkAndChecksumRestrictions()
        print("Whisper model store: failure/cancel resume, persistent verified cache, FIFO installs, corruption and incomplete-model checks passed")
    }

    // Removing verified blobs on a network failure makes this red.
    static func retryAfterFailure() async throws {
        let fixture = try Fixture(fail: true); defer { fixture.clean() }
        let store = fixture.store()
        do { try await store.download(.tiny) { _ in }; throw TestFailure(description: "expected transport failure") }
        catch is URLError {}
        try expect(!store.installed(.tiny), "partial download must not become installed")
        try fixture.assertNoStaging()
        // A new instance models a relaunch; only persistent verified files may be reused.
        try await fixture.store().download(.tiny) { _ in }
        try expect(await fixture.transport.count("/tokenizer.json") == 1, "retry redownloaded a completed verified file after failure")
        try expect(await fixture.transport.count("/tokenizer_config.json") == 2, "unfinished file should restart")
        try store.validate(.tiny)
    }

    // Cancelling a real Task must preserve completed blobs, without promoting the partial model.
    static func retryAfterCancellation() async throws {
        let fixture = try Fixture(hold: true); defer { fixture.clean() }
        let store = fixture.store()
        let first = Task { try await store.download(.tiny) { _ in } }
        await fixture.transport.waitUntilHeld()
        try expect(!store.installed(.tiny), "downloaded subset must not be installed")
        first.cancel()
        await fixture.transport.resume()
        do { try await first.value; throw TestFailure(description: "cancelled download succeeded") }
        catch is CancellationError {}
        try fixture.assertNoStaging()
        try await fixture.store().download(.tiny) { _ in }
        try expect(await fixture.transport.count("/tokenizer.json") == 1, "cancel/retry discarded a completed verified file")
        try expect(await fixture.transport.count("/tokenizer_config.json") == 2, "cancelled current file should restart")
        try store.validate(.tiny)
    }

    // Separate store values sharing one root must not overlap installation or redownload shared blobs.
    static func concurrentInstalls() async throws {
        let fixture = try Fixture(hold: true); defer { fixture.clean() }
        let first = Task { try await fixture.store().download(.tiny) { _ in } }
        await fixture.transport.waitUntilHeld()
        let cancelled = Task { try await fixture.store().download(.base) { _ in } }
        // The queued caller must observe cancellation while the active download is still held.
        try await Task.sleep(for: .milliseconds(40))
        cancelled.cancel()
        do { try await cancelled.value; throw TestFailure(description: "cancelled queued install succeeded") }
        catch is CancellationError {}
        let second = Task { try await fixture.store().download(.base) { _ in } }
        // Let both callers enter the coordinator while the first network operation is held.
        try await Task.sleep(for: .milliseconds(40))
        await fixture.transport.resume()
        try await first.value
        try await second.value
        try expect(await fixture.transport.maximumActive == 1, "downloads for the same root overlapped")
        try expect(await fixture.transport.totalCount() == 5, "overlapping installs failed to reuse checksum-identical assets")
        try fixture.store().validate(.tiny)
        try fixture.store().validate(.base)
        try fixture.assertNoStaging()
    }

    static func badDownloadNeverEntersCache() async throws {
        let fixture = try Fixture(corrupt: true); defer { fixture.clean() }
        let store = fixture.store()
        do { try await store.download(.tiny) { _ in }; throw TestFailure(description: "corrupt download was accepted") }
        catch TranscriptionResourceError.invalidFiles {}
        try expect(!store.installed(.tiny), "bad checksum must not produce a ready model")
        let cache = store.root.appendingPathComponent(".verified-cache")
        try expect(FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty, "unverified download entered persistent cache")
        try fixture.assertNoStaging()
        try await store.download(.tiny) { _ in }
        try expect(await fixture.transport.count("/tokenizer.json") == 2, "bad download must be fetched again")
        try store.validate(.tiny)
    }

    static func catalogRetainsNetworkAndChecksumRestrictions() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = fixture.files[0]
        for (url, checksum) in [("http://huggingface.co/file", original.sha256!),
                                ("https://example.com/file", original.sha256!),
                                (original.url.absoluteString, "../bad-checksum")] {
            var files = fixture.files
            files[0] = WhisperModelFile(path: original.path, url: URL(string: url)!, bytes: original.bytes,
                                        sha256: checksum, gitSHA1: original.gitSHA1)
            try JSONEncoder().encode(["tiny": files]).write(to: fixture.catalog)
            do { try await fixture.store().download(.tiny) { _ in }; throw TestFailure(description: "invalid catalog was accepted") }
            catch TranscriptionResourceError.invalidFiles {}
        }
        try expect(await fixture.transport.totalCount() == 0, "invalid manifest must fail before network access")
    }

    // Same-length cache corruption must never pass as a verified blob.
    static func corruptCacheIsRefetched() async throws {
        let fixture = try Fixture(fail: true); defer { fixture.clean() }
        let store = fixture.store()
        do { try await store.download(.tiny) { _ in }; throw TestFailure(description: "expected failure") }
        catch is URLError {}
        let cache = store.root.appendingPathComponent(".verified-cache")
        let blobs = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try expect(blobs.count == 1, "only fully verified blobs should be cached")
        try Data(repeating: 0, count: Int(fixture.files[0].bytes)).write(to: blobs[0])
        let abandoned = store.root.appendingPathComponent(".download-abandoned")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: abandoned.appendingPathComponent("asset"))
        try await fixture.store().download(.tiny) { _ in }
        try expect(await fixture.transport.count("/tokenizer.json") == 2, "corrupted cache was reused")
        try store.validate(.tiny)
        try fixture.assertNoStaging()
    }

    static func incompleteOrCorruptInstallationIsRejected() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store()
        try await store.download(.tiny) { _ in }
        let file = store.folder(for: .tiny).appendingPathComponent(Fixture.paths[0])
        try Data(repeating: 0, count: Int(fixture.files[0].bytes)).write(to: file)
        do { try store.validate(.tiny); throw TestFailure(description: "same-length installed corruption passed verification") }
        catch TranscriptionResourceError.invalidFiles {}
        try await store.download(.tiny) { _ in }
        try store.validate(.tiny)
        try expect(await fixture.transport.totalCount() == 5, "repair should reuse intact verified cache")
        try FileManager.default.removeItem(at: file)
        try expect(!store.installed(.tiny), "incomplete installed model was ready")
        do { try store.validate(.tiny); throw TestFailure(description: "missing installed asset passed validation") }
        catch TranscriptionResourceError.missing {}
    }
}
