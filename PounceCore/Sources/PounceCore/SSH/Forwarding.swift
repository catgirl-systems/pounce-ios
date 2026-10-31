import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import Synchronization

/// closing stops listening; connections already open finish on their own.
public final class PortForward: Sendable {
    /// the port actually bound: locally for `-L` and `-D`, on the server for `-R`.
    public let port: Int
    public let traffic: TrafficCounter
    private let stop: @Sendable () -> Void

    init(port: Int, traffic: TrafficCounter, stop: @escaping @Sendable () -> Void) {
        self.port = port
        self.traffic = traffic
        self.stop = stop
    }

    public func close() { stop() }
}

extension SSHConnection {
    public func startLocalForward(
        bindHost: String = "127.0.0.1", bindPort: Int, targetHost: String, targetPort: Int
    ) async throws(SSHError) -> PortForward {
        try await listen(host: bindHost, port: bindPort) { [self] inbound, traffic in
            let (local, remote) = GlueHandler.matchedPair(counter: traffic)
            try inbound.pipeline.syncOperations.addHandlers(local, CloseOnErrorHandler())
            let remoteBound = NIOLoopBound(remote, eventLoop: inbound.eventLoop)
            Task {
                do {
                    _ = try await openDirect(host: targetHost, port: targetPort, from: inbound.remoteAddress) {
                        try $0.pipeline.syncOperations.addHandlers(remoteBound.value, CloseOnErrorHandler())
                    }
                } catch {
                    inbound.close(promise: nil)
                }
            }
        }
    }

    public func startDynamicForward(bindHost: String = "127.0.0.1", bindPort: Int) async throws(SSHError)
        -> PortForward
    {
        try await listen(host: bindHost, port: bindPort) { [self] inbound, traffic in
            try inbound.pipeline.syncOperations.addHandler(SOCKS5Handler(connection: self, traffic: traffic))
        }
    }

    public func startRemoteForward(
        bindHost: String = "localhost", bindPort: Int, targetHost: String, targetPort: Int
    ) async throws(SSHError) -> PortForward {
        let traffic = TrafficCounter()
        remoteForwards.register(port: bindPort, target: (targetHost, targetPort), traffic: traffic)
        let response: GlobalRequest.TCPForwardingResponse?
        do {
            response = try await tcpForwarding(.listen(host: bindHost, port: bindPort))
        } catch {
            remoteForwards.unregister(port: bindPort)
            throw .forwardingRejected
        }
        return PortForward(port: response?.boundPort ?? bindPort, traffic: traffic) { [self] in
            remoteForwards.unregister(port: bindPort)
            Task { _ = try? await tcpForwarding(.cancel(host: bindHost, port: bindPort)) }
        }
    }

    private func tcpForwarding(
        _ request: GlobalRequest.TCPForwardingRequest
    ) async throws(SSHError) -> GlobalRequest.TCPForwardingResponse? {
        try await withHandler { handler, loop in
            let promise = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            handler.sendTCPForwardingRequest(request, promise: promise)
            return promise.futureResult
        }
    }

    /// binds on the connection's event loop so accepted sockets and ssh channels
    /// can be glued without hopping threads.
    private func listen(
        host: String, port: Int, accept: @escaping @Sendable (any Channel, TrafficCounter) throws -> Void
    ) async throws(SSHError) -> PortForward {
        let traffic = TrafficCounter()
        do {
            let listener = try await NIOTSListenerBootstrap(group: eventLoop, childGroup: eventLoop)
                .childChannelInitializer { inbound in
                    inbound.eventLoop.makeCompletedFuture { try accept(inbound, traffic) }
                }
                .childTCPOptions(interactiveTCPOptions())
                // half-closure lets one side finish sending after the other is done.
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .bind(host: host, port: port)
                .get()
            channel.closeFuture.whenComplete { _ in listener.close(promise: nil) }
            return PortForward(port: listener.localAddress?.port ?? port, traffic: traffic) {
                listener.close(promise: nil)
            }
        } catch {
            let wrapped = SSHError.wrap(error)
            throw wrapped == .portUnavailable(0) ? .portUnavailable(port) : wrapped
        }
    }
}

// MARK: - remote forwards

final class RemoteForwardRegistry: Sendable {
    private struct Entry: Sendable {
        var host: String
        var port: Int
        var traffic: TrafficCounter
    }
    private let entries = Mutex<[Int: Entry]>([:])

    func register(port: Int, target: (String, Int), traffic: TrafficCounter) {
        entries.withLock { $0[port] = Entry(host: target.0, port: target.1, traffic: traffic) }
    }

    func unregister(port: Int) {
        _ = entries.withLock { $0.removeValue(forKey: port) }
    }

    /// only `forwarded-tcpip` channels for ports we registered are accepted.
    func accept(_ child: any Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = type,
            let entry = entries.withLock({ $0[info.listeningPort] })
        else {
            return child.eventLoop.makeFailedFuture(SSHError.channelRejected)
        }
        let (local, remote) = GlueHandler.matchedPair(counter: entry.traffic)
        let localBound = NIOLoopBound(local, eventLoop: child.eventLoop)
        do {
            try child.pipeline.syncOperations.addHandlers(ChannelDataCodec(), remote, CloseOnErrorHandler())
        } catch {
            return child.eventLoop.makeFailedFuture(error)
        }
        NIOTSConnectionBootstrap(group: child.eventLoop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { outbound in
                outbound.eventLoop.makeCompletedFuture {
                    try outbound.pipeline.syncOperations.addHandlers(localBound.value, CloseOnErrorHandler())
                }
            }
            .connect(host: entry.host, port: entry.port)
            .whenFailure { _ in child.close(promise: nil) }
        return child.eventLoop.makeSucceededVoidFuture()
    }
}

// MARK: - socks5

/// minimal socks5 (rfc 1928): no auth, connect only, ipv4/ipv6/domain targets.
/// once the target is reached it removes itself and glues the two channels.
final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State { case greeting, request, connecting }
    private var state = State.greeting
    private var buffer: ByteBuffer?
    private let connection: SSHConnection
    private let traffic: TrafficCounter

    init(connection: SSHConnection, traffic: TrafficCounter) {
        self.connection = connection
        self.traffic = traffic
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffer == nil { buffer = incoming } else { buffer?.writeBuffer(&incoming) }
        process(context: context)
    }

    private func process(context: ChannelHandlerContext) {
        guard var buf = buffer else { return }
        switch state {
        case .greeting:
            guard let bytes = buf.getBytes(at: buf.readerIndex, length: min(buf.readableBytes, 2)), bytes.count == 2
            else { return }
            guard bytes[0] == 5 else { return fail(context) }
            let count = Int(bytes[1])
            guard buf.readableBytes >= 2 + count, let methods = buf.getBytes(at: buf.readerIndex + 2, length: count)
            else { return }
            buf.moveReaderIndex(forwardBy: 2 + count)
            buffer = buf
            // 0x00: no authentication. anything else is refused with 0xff.
            let accepted = methods.contains(0)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(channel.allocator.buffer(bytes: [5, accepted ? 0 : 0xFF])))
                .whenComplete { _ in if !accepted { channel.close(promise: nil) } }
            guard accepted else { return }
            state = .request
            process(context: context)
        case .request:
            guard let target = parseRequest(&buf) else { return }
            guard case .success(let (command, host, port)) = target else { return fail(context) }
            buffer = buf
            guard command == 1 else { return Self.reply(context.channel, status: 7) }
            state = .connecting
            connect(context: context, host: host, port: port)
        case .connecting:
            break
        }
    }

    /// returns nil until enough bytes arrive.
    private func parseRequest(_ buf: inout ByteBuffer) -> Result<(UInt8, String, Int), SSHError>? {
        guard let head = buf.getBytes(at: buf.readerIndex, length: min(buf.readableBytes, 5)), head.count >= 4 else {
            return nil
        }
        guard head[0] == 5 else { return .failure(.protocolError("SOCKS version")) }
        let command = head[1]
        var offset = 4
        let host: String
        switch head[3] {
        case 1:
            guard let ip = buf.getBytes(at: buf.readerIndex + offset, length: 4) else { return nil }
            host = ip.map(String.init).joined(separator: ".")
            offset += 4
        case 3:
            guard head.count == 5 else { return nil }
            let length = Int(head[4])
            guard let name = buf.getString(at: buf.readerIndex + 5, length: length) else { return nil }
            host = name
            offset += 1 + length
        case 4:
            guard let ip = buf.getBytes(at: buf.readerIndex + offset, length: 16) else { return nil }
            host = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(ip[$0]) << 8 | Int(ip[$0 + 1])) }
                .joined(separator: ":")
            offset += 16
        default:
            return .failure(.protocolError("SOCKS address type"))
        }
        guard let portBytes = buf.getBytes(at: buf.readerIndex + offset, length: 2) else { return nil }
        buf.moveReaderIndex(forwardBy: offset + 2)
        return .success((command, host, Int(portBytes[0]) << 8 | Int(portBytes[1])))
    }

    private func connect(context: ChannelHandlerContext, host: String, port: Int) {
        let inbound = context.channel
        let (local, remote) = GlueHandler.matchedPair(counter: traffic)
        let remoteBound = NIOLoopBound(remote, eventLoop: inbound.eventLoop)
        let handler = NIOLoopBound(self, eventLoop: inbound.eventLoop)
        let localBound = NIOLoopBound(local, eventLoop: inbound.eventLoop)
        let connection = connection
        Task {
            do {
                _ = try await connection.openDirect(host: host, port: port, from: inbound.remoteAddress) {
                    try $0.pipeline.syncOperations.addHandlers(remoteBound.value, CloseOnErrorHandler())
                }
                inbound.eventLoop.execute { handler.value.connected(inbound: inbound, glue: localBound.value) }
            } catch {
                // 0x05: connection refused.
                inbound.eventLoop.execute { Self.reply(inbound, status: 5) }
            }
        }
    }

    private func connected(inbound: any Channel, glue: GlueHandler) {
        Self.reply(inbound, status: 0)
        let leftover = buffer.flatMap { $0.readableBytes > 0 ? $0 : nil }
        buffer = nil
        do {
            let sync = inbound.pipeline.syncOperations
            try sync.addHandlers(glue, CloseOnErrorHandler())
            sync.removeHandler(self).whenSuccess { _ in
                if let leftover { inbound.pipeline.fireChannelRead(leftover) }
            }
        } catch {
            inbound.close(promise: nil)
        }
    }

    /// replies bound to 0.0.0.0:0 (clients ignore it), closing afterwards unless
    /// the request succeeded.
    private static func reply(_ channel: any Channel, status: UInt8) {
        channel.writeAndFlush(channel.allocator.buffer(bytes: [5, status, 0, 1, 0, 0, 0, 0, 0, 0]))
            .whenComplete { _ in if status != 0 { channel.close(promise: nil) } }
    }

    private func fail(_ context: ChannelHandlerContext) { context.close(promise: nil) }
}
