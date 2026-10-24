import XCTest
@testable import CompanionCore

final class RuntimeTests: XCTestCase {
    let request = TextRequest(model: "test-model", system: "system", user: "user")
    func testSerializedQueueAndBusy() async throws {
        let engine = StubEngine(delay: .milliseconds(80)), device = UUID()
        let runtime = try await readyRuntime(engine: engine, queueLimit: 1)
        let first = Task { try await runtime.generate(request, device: device) }
        try await waitUntil { await runtime.snapshot().active }
        let second = Task { try await runtime.generate(request, device: device) }
        try await waitUntil { await runtime.snapshot().queued == 1 }
        do { _ = try await runtime.generate(request, device: device); XCTFail("Queue exceeded bound") }
        catch { XCTAssertEqual(error as? ServiceError, .busy) }
        _ = try await first.value; _ = try await second.value
        let maximum = await engine.maximumActive
        XCTAssertEqual(maximum, 1)
        await runtime.shutdown()
    }
    func testCancellationAndRevocationCancelQueuedWork() async throws {
        let engine = StubEngine(delay: .seconds(2)), device = UUID()
        let runtime = try await readyRuntime(engine: engine)
        let first = Task { try await runtime.generate(request, device: device) }
        try await waitUntil { await runtime.snapshot().active }
        let second = Task { try await runtime.generate(request, device: device) }
        try await waitUntil { await runtime.snapshot().queued == 1 }
        await runtime.revoke(device: device)
        for task in [first, second] { do { _ = try await task.value; XCTFail("Revoked work succeeded") } catch { XCTAssertEqual(error as? ServiceError, .cancelled) } }
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 1)
        do { _ = try await runtime.generate(request, device: device); XCTFail("Revoked device was readmitted") } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
        await runtime.shutdown()
    }
    func testTimeoutAndIdleUnload() async throws {
        let runtime = try await readyRuntime(engine: StubEngine(delay: .seconds(2)), timeout: .milliseconds(25))
        do { _ = try await runtime.generate(request, device: UUID()); XCTFail("Timeout did not fire") } catch { XCTAssertEqual(error as? ServiceError, .timeout) }
        await runtime.unloadIfIdle(now: Date().addingTimeInterval(601))
        let state = await runtime.snapshot().state
        XCTAssertEqual(state, .unloaded)
        do { _ = try await runtime.generate(request, device: UUID()); XCTFail("Unloaded model ran") } catch { XCTAssertEqual(error as? ServiceError, .notReady) }
    }
    func testCallerCancellationAndWrongModel() async throws {
        let runtime = try await readyRuntime(engine: StubEngine(delay: .seconds(1)))
        do { _ = try await runtime.generate(.init(model: "other", system: "s", user: "u"), device: UUID()); XCTFail("Accepted wrong model") }
        catch { XCTAssertEqual((error as? ServiceError)?.code, "unknown_model") }
        let task = Task { try await runtime.generate(request, device: UUID()) }
        try await waitUntil { await runtime.snapshot().active }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task succeeded") } catch { XCTAssertEqual(error as? ServiceError, .cancelled) }
        await runtime.shutdown()
    }
    func testShutdownWaitsForActiveWorkAndCancelsPending() async throws {
        let engine = StubEngine(delay: .seconds(2)), runtime = try await readyRuntime(engine: engine)
        let first = Task { try await runtime.generate(request, device: UUID()) }
        try await waitUntil { await runtime.snapshot().active }
        let second = Task { try await runtime.generate(request, device: UUID()) }
        try await waitUntil { await runtime.snapshot().queued == 1 }
        await runtime.shutdown()
        let active = await engine.active, snapshot = await runtime.snapshot()
        XCTAssertEqual(active, 0); XCTAssertEqual(snapshot.queued, 0); XCTAssertEqual(snapshot.state, .unloaded)
        for task in [first, second] { do { _ = try await task.value; XCTFail("Shutdown work succeeded") } catch { XCTAssertEqual(error as? ServiceError, .cancelled) } }
    }
}
