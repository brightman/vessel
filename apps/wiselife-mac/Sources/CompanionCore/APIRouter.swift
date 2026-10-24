import Foundation

public actor APIRouter {
    public let registry: PairingRegistry
    public let runtime: ModelRuntime
    private var available = false
    public init(registry: PairingRegistry, runtime: ModelRuntime) { self.registry = registry; self.runtime = runtime }
    public func setAvailable(_ value: Bool) async {
        available = value
        if value { await runtime.resume() } else { await runtime.suspend() }
    }
    public func handle(method: String, path: String, authorization: String?, body: Data, peer: String) async -> APIResponse {
        do {
            guard body.count <= TextRequest.maximumBodyBytes else { throw ServiceError.bodyTooLarge }
            if method == "GET", path == "/health" {
                let snapshot = await runtime.snapshot()
                return .init(object: ["service_version": "1.0", "protocol_version": 1,
                    "model_state": snapshot.state.rawValue, "active": snapshot.active, "queued": snapshot.queued,
                    "available": available])
            }
            if method == "POST", path == "/pair" {
                guard let input = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      Set(input.keys) == ["nonce", "device_id", "device_name"],
                      let nonce = input["nonce"] as? String, nonce.utf8.count <= 128,
                      let id = input["device_id"] as? String, let deviceID = UUID(uuidString: id),
                      let name = input["device_name"] as? String else { throw ServiceError.invalidRequest }
                let token = try await registry.pair(nonce: nonce, deviceID: deviceID, name: name, peer: peer)
                await runtime.revoke(device: deviceID) // Rotating an existing device also cancels its old work.
                await runtime.allow(device: deviceID)
                return .init(object: ["token": token, "device_id": id, "service_id": await registry.serviceID, "protocol_version": 1])
            }
            let device = try await registry.authenticate(authorization)
            if method == "DELETE", path == "/pair" {
                try await registry.revoke(device.id); await runtime.revoke(device: device.id)
                return .init(object: ["revoked": true])
            }
            guard available else { throw ServiceError(503, "service_paused", "Mac 已暂停提供本地 AI，请在 Mac 上开启。") }
            if method == "GET", path == "/v1/models" {
                let snapshot = await runtime.snapshot()
                let models: [[String: Any]] = snapshot.modelID.map { [["id": $0, "object": "model", "owned_by": "local", "ready": snapshot.state == .ready]] } ?? []
                return .init(object: ["object": "list", "data": models])
            }
            if method == "POST", path == "/v1/chat/completions" {
                let request = try TextRequest.parse(body)
                // Revocation/availability are checked again at admission, after parsing.
                _ = try await registry.authenticate(authorization)
                guard available else { throw ServiceError.notReady }
                let result = try await runtime.generate(request, device: device.id)
                _ = try await registry.authenticate(authorization)
                guard available else { throw ServiceError.cancelled }
                return .init(object: ["id": "chatcmpl-" + UUID().uuidString, "object": "chat.completion",
                    "created": Int(Date().timeIntervalSince1970), "model": request.model,
                    "choices": [["index": 0, "message": ["role": "assistant", "content": result.text], "finish_reason": result.finishReason]],
                    "usage": ["prompt_tokens": result.promptTokens, "completion_tokens": result.generatedTokens, "total_tokens": result.promptTokens + result.generatedTokens]])
            }
            throw ServiceError(404, "not_found", "不支持的接口。")
        } catch let error as ServiceError { return .error(error) }
        catch is CancellationError { return .error(.cancelled) }
        catch { return .error(.inference) }
    }
    public func revoke(_ id: UUID) async throws { try await registry.revoke(id); await runtime.revoke(device: id) }
    public func stop() async {
        available = false; await registry.close(); await runtime.suspend()
    }
}
