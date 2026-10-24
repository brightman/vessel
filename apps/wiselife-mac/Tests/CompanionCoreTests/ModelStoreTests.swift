import XCTest
@testable import CompanionCore

private struct FixtureFetcher: ModelFileFetcher {
    let corrupt: Bool
    func fetch(_ url: URL, to destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        XCTAssertEqual(url.scheme, "https"); XCTAssertTrue(url.path.contains(String(repeating: "a", count: 40)))
        try Data((corrupt ? "evil" : "test").utf8).write(to: destination)
        progress(4)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DownloadProgress] = []
    func append(_ value: DownloadProgress) { lock.lock(); entries.append(value); lock.unlock() }
    func snapshot() -> [DownloadProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class ModelStoreTests: XCTestCase {
    private var fixture: CatalogModel {
        CatalogModel(id: "mlx-community/fixture", name: "Fixture", revision: String(repeating: "a", count: 40), license: "Apache-2.0", source: "https://huggingface.co/mlx-community/fixture", acceptance: "test",
            files: [.init(name: "model.safetensors", bytes: 4, sha256: Secrets.hash("test")), .init(name: "config.json", bytes: 4, sha256: Secrets.hash("test"))])
    }
    func testPromotesOnlyVerifiedCompleteModelAndRechecksBeforeLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = fixture, store = try ModelStore(root: root, fetcher: FixtureFetcher(corrupt: false))
        try await store.install(model) { _ in }
        let installed = await store.isInstalled(model)
        XCTAssertTrue(installed)
        let directory = try await store.verifiedDirectory(model)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [model.directoryName])
        try Data("evil".utf8).write(to: directory.appendingPathComponent("config.json"))
        do { _ = try await store.verifiedDirectory(model); XCTFail("Tampered file loaded") }
        catch { XCTAssertEqual((error as? ServiceError)?.code, "model_integrity_failed") }
        try await store.remove(model)
        let after = await store.isInstalled(model)
        XCTAssertFalse(after)
    }
    func testFailedVerificationLeavesNoInstalledOrStagingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = fixture, store = try ModelStore(root: root, fetcher: FixtureFetcher(corrupt: true))
        do { try await store.install(model) { _ in }; XCTFail("Corrupt download succeeded") } catch { }
        let installed = await store.isInstalled(model)
        XCTAssertFalse(installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testProgressDistinguishesDownloadVerificationAndInstalledCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = fixture, store = try ModelStore(root: root, fetcher: FixtureFetcher(corrupt: false))
        let recorder = ProgressRecorder()
        try await store.install(model) { recorder.append($0) }
        let events = recorder.snapshot()
        XCTAssertEqual(events.first?.phase, .downloading)
        XCTAssertEqual(events.filter { $0.phase == .verifying }.count, model.files.count)
        XCTAssertEqual(events.last?.phase, .complete)
        XCTAssertEqual(events.last?.bytes, model.bytes)
        XCTAssertEqual(events.last?.fraction, 1)
        XCTAssertEqual(events.map(\.bytes), events.map(\.bytes).sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(model.directoryName).appendingPathComponent("verified.json").path))
        let failedRecorder = ProgressRecorder()
        let corruptRoot = root.appendingPathComponent("corrupt")
        let corrupt = try ModelStore(root: corruptRoot, fetcher: FixtureFetcher(corrupt: true))
        do { try await corrupt.install(model) { failedRecorder.append($0) }; XCTFail("Corrupt model installed") } catch { }
        XCTAssertFalse(failedRecorder.snapshot().contains { $0.phase == .complete })
    }
}
