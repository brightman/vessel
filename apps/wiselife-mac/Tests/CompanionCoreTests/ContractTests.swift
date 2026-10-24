import XCTest
@testable import CompanionCore

final class ContractTests: XCTestCase {
    func testStrictTextSurfaceAndClamp() throws {
        let request = try TextRequest.parse(requestBody(["max_tokens": 9000, "temperature": 0]))
        XCTAssertEqual(request.maxTokens, 2048); XCTAssertEqual(request.temperature, 0)
        XCTAssertEqual(request.system, "只按原文回答"); XCTAssertEqual(request.user, "只发送本条文字")
        for bad: [String: Any] in [
            ["stream": true], ["stream": 0], ["max_tokens": true], ["max_tokens": 0], ["max_tokens": 1.5],
            ["temperature": true], ["temperature": 1.1], ["tools": []], ["response_format": [:]],
            ["messages": [["role": "user", "content": "x"]]],
            ["messages": [["role": "system", "content": "x"], ["role": "user", "content": [["type": "image_url"]]]]],
            ["messages": [["role": "system", "content": "x"], ["role": "user", "content": "x", "name": "hidden"]]],
        ] { XCTAssertThrowsError(try TextRequest.parse(requestBody(bad)), "Accepted unsupported input: \(bad.keys)") }
        XCTAssertThrowsError(try TextRequest.parse(Data(repeating: 32, count: TextRequest.maximumBodyBytes + 1))) { error in
            XCTAssertEqual(error as? ServiceError, .bodyTooLarge)
        }
    }
    func testCatalogContainsImmutablePinsAndHashes() throws {
        let catalog = try CatalogModel.bundled()
        XCTAssertEqual(catalog.count, 2)
        for model in catalog {
            XCTAssertEqual(model.license, "Apache-2.0"); XCTAssertEqual(model.revision.count, 40)
            XCTAssertTrue(model.files.contains { $0.name == "model.safetensors" })
            for file in model.files { XCTAssertEqual(file.sha256.count, 64); XCTAssertGreaterThan(file.bytes, 0) }
        }
    }
    func testOnlyPrivateInterfacesAllowed() {
        for address in ["192.168.1.2", "10.0.0.2", "172.16.0.4", "172.31.9.9", "169.254.2.3"] { XCTAssertTrue(LocalInterface.isPrivateIPv4(address)) }
        for address in ["0.0.0.0", "127.0.0.1", "8.8.8.8", "172.32.0.1", "192.168.1.999", "::"] { XCTAssertFalse(LocalInterface.isPrivateIPv4(address)) }
    }
    func testModelIntegrityRejectsTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json"), bytes = Data("test".utf8)
        try bytes.write(to: file)
        let manifest = CatalogModel.File(name: "config.json", bytes: 4, sha256: Secrets.hash(bytes))
        try ModelStore.verify(file, file: manifest)
        try Data("evil".utf8).write(to: file)
        XCTAssertThrowsError(try ModelStore.verify(file, file: manifest))
    }
}
