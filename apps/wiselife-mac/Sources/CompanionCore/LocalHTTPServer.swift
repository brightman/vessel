import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// No wildcard/public bind is accepted. Production callers supply a current RFC1918
/// or link-local interface address; loopback is only for deterministic transport tests.
public actor LocalHTTPServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var starting: Task<Channel, Error>?
    private var stopping: Task<Void, Never>?
    private var lifecycle: UInt64 = 0
    private let connections = Connections()
    public init() {}
    public func start(address: String, identity: TLSIdentity, router: APIRouter, allowLoopbackForTests: Bool = false) async throws -> Int {
        guard listener == nil, group == nil, stopping == nil else { throw ServiceError.busy }
        guard LocalInterface.isPrivateIPv4(address) || (allowLoopbackForTests && address == "127.0.0.1") else {
            throw ServiceError(503, "no_local_interface", "请连接可供 iPhone 访问的局域网。")
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2), connections = self.connections
        let generation = lifecycle
        self.group = group
        do {
            let task = Task {
                try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 32)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 8)
                .childChannelInitializer { channel in
                    let peer = channel.remoteAddress?.ipAddress ?? ""
                    guard LocalInterface.isPrivateIPv4(peer) || (allowLoopbackForTests && peer == "127.0.0.1"), connections.add(channel) else {
                        return channel.close()
                    }
                    do {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: identity.context))
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false)
                        try channel.pipeline.syncOperations.addHandler(HTTPRequestHandler(router: router, peer: peer, connections: connections))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: address, port: 0).get()
            }
            starting = task
            let channel = try await task.value
            guard generation == lifecycle else { throw ServiceError.cancelled }
            listener = channel; starting = nil
            return channel.localAddress!.port!
        } catch {
            guard generation == lifecycle else { throw ServiceError.cancelled }
            await connections.closeAll()
            try? await group.shutdownGracefully()
            if generation == lifecycle { self.group = nil; starting = nil }
            throw ServiceError(503, "listener_failed", "无法启动局域网服务，请检查网络和防火墙权限。")
        }
    }
    public func stop() async {
        if let task = stopping { await task.value; return }
        lifecycle &+= 1
        let channel = listener, group = group, pending = starting, connections = self.connections
        let task = Task {
            if let pending, case .success(let bound) = await pending.result { try? await bound.close().get() }
            try? await channel?.close().get()
            await connections.closeAll()
            try? await group?.shutdownGracefully()
        }
        stopping = task
        await task.value
        self.group = nil; listener = nil; starting = nil; stopping = nil
    }
}

private final class Connections: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    func add(_ channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard channels.count < 24 else { return false }
        channels[ObjectIdentifier(channel)] = channel
        // Also removes TLS handshake failures, before the HTTP handler is installed.
        channel.closeFuture.whenComplete { [weak self, weak channel] _ in
            if let channel { self?.remove(channel) }
        }
        return true
    }
    func remove(_ channel: Channel) { lock.lock(); channels.removeValue(forKey: ObjectIdentifier(channel)); lock.unlock() }
    func closeAll() async {
        let all = snapshot()
        for channel in all { try? await channel.close().get() }
    }
    private func snapshot() -> [Channel] { lock.lock(); defer { lock.unlock() }; return Array(channels.values) }
}

private final class HTTPRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let router: APIRouter
    private let peer: String
    private let connections: Connections
    private var head: HTTPRequestHead?
    private var body = Data()
    private var processing = false
    private var responded = false
    private var task: Task<Void, Never>?
    private var readDeadline: Scheduled<Void>?
    private var context: ChannelHandlerContext?
    init(router: APIRouter, peer: String, connections: Connections) { self.router = router; self.peer = peer; self.connections = connections }
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        readDeadline = context.eventLoop.scheduleTask(in: .seconds(20)) { [weak self] in
            self?.task?.cancel()
            context.close(promise: nil)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil, !processing, head.uri.utf8.count < 256,
                  head.uri.hasPrefix("/"), !head.uri.contains("?"),
                  head.headers["authorization"].count <= 1, head.headers["content-length"].count <= 1,
                  !head.headers.contains(name: "upgrade"), !head.headers.contains(name: "expect") else {
                respond(.error(.invalidRequest), context: context); return
            }
            if let size = head.headers.first(name: "content-length"), (Int(size) ?? Int.max) > TextRequest.maximumBodyBytes {
                respond(.error(.bodyTooLarge), context: context); return
            }
            if head.method == .POST, !(head.headers.first(name: "content-type") ?? "").lowercased().hasPrefix("application/json") {
                respond(.error(.init(415, "unsupported_media_type", "请使用 application/json。")), context: context); return
            }
            self.head = head
        case .body(var chunk):
            guard !processing, body.count + chunk.readableBytes <= TextRequest.maximumBodyBytes else {
                respond(.error(.bodyTooLarge), context: context); return
            }
            body.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
        case .end(let trailers):
            guard !processing, let head, trailers == nil else { respond(.error(.invalidRequest), context: context); return }
            processing = true; readDeadline?.cancel()
            let data = body; body = Data()
            let channel = context.channel, router = self.router, peer = self.peer
            task = Task {
                let response = await router.handle(method: head.method.rawValue, path: head.uri, authorization: head.headers.first(name: "authorization"), body: data, peer: peer)
                channel.eventLoop.execute { [weak self] in
                    // This stored context is read and used only on its owning event loop.
                    guard let self, let context = self.context else { return }
                    self.respond(response, context: context)
                }
            }
        }
    }
    private func respond(_ response: APIResponse, context: ChannelHandlerContext) {
        guard !responded, context.channel.isActive else { return }
        responded = true; body = Data(); head = nil; readDeadline?.cancel(); task = nil
        var headers = HTTPHeaders([("Content-Type", "application/json; charset=utf-8"), ("Content-Length", String(response.body.count)),
            ("Cache-Control", "no-store"), ("Connection", "close"), ("X-Content-Type-Options", "nosniff")])
        if response.status == 429 || response.status == 503 { headers.add(name: "Retry-After", value: "5") }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .init(statusCode: response.status), headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count); buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        task?.cancel(); task = nil; readDeadline?.cancel(); body = Data(); head = nil
        connections.remove(context.channel); context.fireChannelInactive()
        self.context = nil
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        task?.cancel(); respond(.error(.invalidRequest), context: context); context.close(promise: nil)
    }
}
