import Foundation
import NIOCore
import NIOSSH
import Synchronization

/// lets a child channel be glued to a tcp socket or carry another ssh
/// connection (jump hosts).
final class ChannelDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        // only the main stream is payload; extended data (stderr) is dropped.
        guard data.type == .channel, case .byteBuffer(let buffer) = data.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

public final class TrafficCounter: Sendable {
    private let sent = Atomic<Int>(0)
    private let received = Atomic<Int>(0)
    private let open = Atomic<Int>(0)

    public init() {}

    public var bytesSent: Int { sent.load(ordering: .relaxed) }
    public var bytesReceived: Int { received.load(ordering: .relaxed) }
    public var openConnections: Int { open.load(ordering: .relaxed) }

    func addSent(_ n: Int) { sent.add(n, ordering: .relaxed) }
    func addReceived(_ n: Int) { received.add(n, ordering: .relaxed) }
    func connectionOpened() { open.add(1, ordering: .relaxed) }
    func connectionClosed() { open.subtract(1, ordering: .relaxed) }
}

/// adapted from swift-nio-ssh's port forwarding example.
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// ssh channels deliver data as soon as they open, which can be before the
    /// socket on the other end has connected, so it's queued until then.
    private var queued: [NIOAny] = []
    private var closeWhenAdded = false
    /// eof that arrived before this side was active, queued like `queued`.
    private var eofWhenActive = false
    /// set on the local side only, so each byte is counted once.
    private let counter: TrafficCounter?

    private init(counter: TrafficCounter?) { self.counter = counter }

    /// the first handler goes on the local socket, the second on the ssh side.
    static func matchedPair(counter: TrafficCounter?) -> (GlueHandler, GlueHandler) {
        let local = GlueHandler(counter: counter)
        let remote = GlueHandler(counter: nil)
        local.partner = remote
        remote.partner = local
        return (local, remote)
    }

    private func partnerWrite(_ data: NIOAny) {
        if let context, context.channel.isActive, queued.isEmpty {
            context.write(data, promise: nil)
        } else {
            queued.append(data)
        }
    }
    private func partnerFlush() { context?.flush() }
    // flush before closing: eof often arrives before the read-complete that
    // would have flushed, and closing drops unflushed writes.
    private func partnerWriteEOF() {
        guard let context, context.channel.isActive, queued.isEmpty else {
            eofWhenActive = true
            return
        }
        context.flush()
        context.close(mode: .output, promise: nil)
    }
    private func partnerCloseFull() {
        guard let context, context.channel.isActive else {
            closeWhenAdded = true
            return
        }
        context.flush()
        context.close(promise: nil)
    }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        counter?.connectionOpened()
        // an outgoing socket joins its pipeline before it connects; queued data
        // waits until it's active.
        if context.channel.isActive { drainQueue(context) }
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        counter?.connectionClosed()
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let count = unwrapInboundIn(data).readableBytes
        counter?.addSent(count)
        partner?.counter?.addReceived(count)
        partner?.partnerWrite(data)
    }

    func channelActive(context: ChannelHandlerContext) {
        drainQueue(context)
        context.fireChannelActive()
    }

    private func drainQueue(_ context: ChannelHandlerContext) {
        if !queued.isEmpty {
            for data in queued { context.write(data, promise: nil) }
            queued = []
            context.flush()
        }
        if eofWhenActive {
            eofWhenActive = false
            context.close(mode: .output, promise: nil)
        }
        if closeWhenAdded {
            closeWhenAdded = false
            context.close(promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
