import Foundation
import NIOCore
import NIOSSH
import Synchronization

public final class SSHShell: Sendable {
    let channel: any Channel
    /// ends when the shell exits or the connection drops.
    public let output: AsyncStream<[UInt8]>
    private let status: LockedBox<Int>

    init(channel: any Channel, output: AsyncStream<[UInt8]>, status: LockedBox<Int>) {
        self.channel = channel
        self.output = output
        self.status = status
    }

    public var exitStatus: Int? { status.value }

    public func write(_ bytes: some Sequence<UInt8>) {
        let buffer = channel.allocator.buffer(bytes: bytes)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    public func resize(columns: Int, rows: Int) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    public func close() { channel.close(promise: nil) }
}

public struct SSHCommandResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int?
}

extension SSHConnection {
    public func openShell(
        columns: Int, rows: Int, term: String = "xterm-256color", environment: [String: String] = [:]
    ) async throws(SSHError) -> SSHShell {
        let (output, continuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        let status = LockedBox<Int>()
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: term, terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        let channel = try await openChildChannel(type: .session) { child in
            try child.pipeline.syncOperations.addHandler(
                SessionHandler(
                    requests: [.pty(pty)] + environment.map { .env($0.key, $0.value) } + [.shell],
                    onData: { continuation.yield($0) },
                    onExit: { status.set($0) },
                    onClose: { continuation.finish() }))
        }
        continuation.onTermination = { _ in channel.close(promise: nil) }
        return SSHShell(channel: channel, output: output, status: status)
    }

    public func run(_ command: String) async throws(SSHError) -> SSHCommandResult {
        let result = Mutex(SSHCommandResult(stdout: Data(), stderr: Data(), exitStatus: nil))
        let done = eventLoop.makePromise(of: Void.self)
        let channel = try await openChildChannel(type: .session) { child in
            try child.pipeline.syncOperations.addHandler(
                SessionHandler(
                    requests: [.exec(command)],
                    onData: { data in result.withLock { $0.stdout.append(contentsOf: data) } },
                    onError: { data in result.withLock { $0.stderr.append(contentsOf: data) } },
                    onExit: { status in result.withLock { $0.exitStatus = status } },
                    onClose: { done.succeed() }))
        }
        do {
            try await done.futureResult.get(closing: channel)
        } catch {
            throw .wrap(error)
        }
        return result.withLock { $0 }
    }
}

/// sends the session's requests once the channel opens.
final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    enum Request {
        case pty(SSHChannelRequestEvent.PseudoTerminalRequest)
        case env(String, String)
        case shell
        case exec(String)
    }

    private let requests: [Request]
    private let onData: @Sendable ([UInt8]) -> Void
    private let onError: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int) -> Void
    private let onClose: @Sendable () -> Void

    init(
        requests: [Request], onData: @escaping @Sendable ([UInt8]) -> Void,
        onError: (@Sendable ([UInt8]) -> Void)? = nil, onExit: @escaping @Sendable (Int) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.requests = requests
        self.onData = onData
        // a pty merges stderr into its output; commands keep it apart.
        self.onError = onError ?? onData
        self.onExit = onExit
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // half-closure keeps the channel readable after the server's eof, until
        // the exit status arrives.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        for request in requests {
            let event: Any =
                switch request {
                case .pty(let pty): pty
                case .env(let name, let value):
                    SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
                case .shell: SSHChannelRequestEvent.ShellRequest(wantReply: true)
                case .exec(let command): SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                }
            context.triggerUserOutboundEvent(event, promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Array(buffer.readableBytesView)
        if message.type == .stdErr { onError(bytes) } else { onData(bytes) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            onExit(status.exitStatus)
        case is ChannelFailureEvent:
            // the server refused the shell or command.
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }
}
