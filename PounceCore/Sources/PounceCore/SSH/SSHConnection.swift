import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import Network
import Synchronization
import os

let sshLog = Logger(subsystem: "catgirl.engineering.pounce", category: "ssh")

public struct SSHEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    public var description: String { port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)" }
}

/// keys are tried before passwords.
public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

public struct SSHHop: Sendable {
    public var endpoint: SSHEndpoint
    public var credentials: [SSHCredential]

    public init(endpoint: SSHEndpoint, credentials: [SSHCredential]) {
        self.endpoint = endpoint
        self.credentials = credentials
    }
}

public enum ConnectStage: Int, Sendable, Comparable {
    case connecting, securing, authenticating, ready
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// hop index 0 is the first jump host, or the target if there are none.
public struct SSHConnectHandlers: Sendable {
    /// asking the user is fine: the handshake waits.
    public var verifyHostKey: @Sendable (_ hop: Int, _ endpoint: SSHEndpoint, _ key: SSHPublicKey) async -> Bool
    /// only called once every stored password has failed.
    public var askPassword: @Sendable (_ hop: Int, _ endpoint: SSHEndpoint) async -> String?
    public var progress: @Sendable (_ hop: Int, _ stage: ConnectStage) -> Void

    public init(
        verifyHostKey: @escaping @Sendable (Int, SSHEndpoint, SSHPublicKey) async -> Bool,
        askPassword: @escaping @Sendable (Int, SSHEndpoint) async -> String? = { _, _ in nil },
        progress: @escaping @Sendable (Int, ConnectStage) -> Void = { _, _ in }
    ) {
        self.verifyHostKey = verifyHostKey
        self.askPassword = askPassword
        self.progress = progress
    }
}

/// closing it closes the whole jump host chain.
public final class SSHConnection: Sendable {
    public let endpoint: SSHEndpoint
    let channel: any Channel
    let parent: SSHConnection?
    let remoteForwards: RemoteForwardRegistry

    private init(endpoint: SSHEndpoint, channel: any Channel, parent: SSHConnection?, registry: RemoteForwardRegistry) {
        self.endpoint = endpoint
        self.channel = channel
        self.parent = parent
        self.remoteForwards = registry
    }

    public static func connect(
        _ hops: [SSHHop], handlers: SSHConnectHandlers
    ) async throws(SSHError) -> SSHConnection {
        guard !hops.isEmpty else { throw .noCredentials }
        var current: SSHConnection?
        do {
            for (index, hop) in hops.enumerated() {
                current = try await connectHop(hop, index: index, via: current, handlers: handlers)
            }
        } catch {
            current?.close()
            throw error
        }
        guard let current else { throw .disconnected }
        // keepalives on the last hop travel through every jump host too.
        current.startHeartbeat()
        return current
    }

    private static func connectHop(
        _ hop: SSHHop, index: Int, via parent: SSHConnection?, handlers: SSHConnectHandlers
    ) async throws(SSHError) -> SSHConnection {
        let failure = LockedBox<SSHError>()
        let registry = RemoteForwardRegistry()
        let authenticated = NIOTSEventLoopGroup.singleton.next().makePromise(of: Void.self)
        handlers.progress(index, .connecting)

        // the first hop runs over tcp, later ones over a `direct-tcpip` channel
        // through the previous hop.
        let setup: @Sendable (any Channel) throws -> Void = { channel in
            let delegate = HopDelegate(hop: hop, index: index, handlers: handlers, failure: failure)
            let ssh = NIOSSHHandler(
                role: .client(.init(userAuthDelegate: delegate, serverAuthDelegate: delegate)),
                allocator: channel.allocator,
                inboundChildChannelInitializer: { child, type in
                    registry.accept(child, type: type)
                })
            let watcher = AuthWatcher(promise: authenticated, failure: failure)
            try channel.pipeline.syncOperations.addHandlers(ssh, watcher)
            // `NIOSSHHandler` doesn't forward `channelInactive`, so the watcher
            // learns about the close from the close future.
            let bound = NIOLoopBound(watcher, eventLoop: channel.eventLoop)
            channel.closeFuture.whenComplete { _ in bound.value.closed() }
        }

        let channel: any Channel
        do {
            if let parent {
                channel = try await parent.openDirect(
                    host: hop.endpoint.host, port: hop.endpoint.port, configure: setup)
            } else {
                channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
                    .connectTimeout(.seconds(12))
                    .tcpOptions(interactiveTCPOptions())
                    // fail fast on a refused port instead of letting network.framework
                    // retry until the timeout.
                    .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture { try setup(channel) }
                    }
                    .connect(host: hop.endpoint.host, port: hop.endpoint.port)
                    .get()
            }
        } catch {
            authenticated.fail(error)
            throw SSHError.wrap(error)
        }
        handlers.progress(index, .securing)

        do {
            try await authenticated.futureResult.get(closing: channel)
        } catch {
            channel.close(promise: nil)
            throw failure.value ?? SSHError.wrap(error)
        }
        sshLog.info("hop \(index) ready: \(hop.endpoint.description, privacy: .private)")
        handlers.progress(index, .ready)
        return SSHConnection(endpoint: hop.endpoint, channel: channel, parent: parent, registry: registry)
    }

    /// `configure` runs on the event loop before the channel becomes active.
    func openChildChannel(
        type: SSHChannelType, configure: @escaping @Sendable (any Channel) throws -> Void
    ) async throws(SSHError) -> any Channel {
        let channel = self.channel
        let promise = channel.eventLoop.makePromise(of: (any Channel).self)
        channel.eventLoop.execute {
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: type) { child, _ in
                    child.eventLoop.makeCompletedFuture { try configure(child) }
                }
            } catch {
                promise.fail(error)
            }
        }
        do {
            return try await promise.futureResult.get()
        } catch let error as NIOSSHError where error.type == .channelSetupRejected {
            throw .channelRejected
        } catch {
            throw .wrap(error)
        }
    }

    /// `origin` is the address the server logs as the client.
    func openDirect(
        host: String, port: Int, from origin: SocketAddress? = nil,
        configure: @escaping @Sendable (any Channel) throws -> Void
    ) async throws(SSHError) -> any Channel {
        let originator: SocketAddress
        do { originator = try origin ?? SocketAddress(ipAddress: "127.0.0.1", port: 0) } catch { throw .wrap(error) }
        let target = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: originator)
        return try await openChildChannel(type: .directTCPIP(target)) { child in
            try child.pipeline.syncOperations.addHandler(ChannelDataCodec())
            try configure(child)
        }
    }

    func withHandler<T: Sendable>(
        _ body: @escaping @Sendable (NIOSSHHandler, any EventLoop) throws -> EventLoopFuture<T>
    )
        async throws(SSHError) -> T
    {
        let channel = self.channel
        do {
            return try await channel.eventLoop.flatSubmit {
                do {
                    return try body(
                        channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self), channel.eventLoop)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.get()
        } catch {
            throw .wrap(error)
        }
    }

    public var isActive: Bool { channel.isActive }

    public func close() {
        channel.close(promise: nil)
        parent?.close()
    }

    public func waitUntilClosed() async {
        _ = try? await channel.closeFuture.get()
    }

    var eventLoop: any EventLoop { channel.eventLoop }
}

extension EventLoopFuture where Value: Sendable {
    /// closes `channel` if the waiting task is cancelled.
    func get(closing channel: any Channel) async throws -> Value {
        try await withTaskCancellationHandler {
            try await get()
        } onCancel: {
            channel.close(promise: nil)
        }
    }
}

/// no nagle delay, and tcp keepalives so a dead network is noticed within
/// about a minute.
func interactiveTCPOptions() -> NWProtocolTCP.Options {
    let options = NWProtocolTCP.Options()
    options.noDelay = true
    options.enableKeepalive = true
    options.keepaliveIdle = 30
    options.keepaliveInterval = 10
    options.keepaliveCount = 3
    return options
}

// MARK: - delegates

/// keeps the first failure our delegates report, which is more specific than
/// the generic error nio raises afterwards.
final class LockedBox<Value: Sendable>: Sendable {
    private let stored = Mutex<Value?>(nil)
    var value: Value? { stored.withLock { $0 } }
    func set(_ new: Value) { stored.withLock { if $0 == nil { $0 = new } } }
}

/// offers every key, then every stored password, then asks for one.
final class HopDelegate: NIOSSHClientUserAuthenticationDelegate, NIOSSHClientServerAuthenticationDelegate {
    private let hop: SSHHop
    private let index: Int
    private let handlers: SSHConnectHandlers
    private let failure: LockedBox<SSHError>
    private var next = 0
    private var asked = 0

    init(hop: SSHHop, index: Int, handlers: SSHConnectHandlers, failure: LockedBox<SSHError>) {
        self.hop = hop
        self.index = index
        self.handlers = handlers
        self.failure = failure
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if next == 0 && asked == 0 { handlers.progress(index, .authenticating) }
        let username = hop.endpoint.username
        let ordered =
            hop.credentials.filter { if case .privateKey = $0 { true } else { false } }
            + hop.credentials.filter { if case .password = $0 { true } else { false } }
        while next < ordered.count {
            let credential = ordered[next]
            next += 1
            switch credential {
            case .privateKey(let key) where availableMethods.contains(.publicKey):
                nextChallengePromise.succeed(
                    .init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
                return
            case .password(let password) where availableMethods.contains(.password):
                nextChallengePromise.succeed(
                    .init(username: username, serviceName: "", offer: .password(.init(password: password))))
                return
            default:
                continue
            }
        }
        // nothing stored worked: ask up to three times, like openssh.
        guard availableMethods.contains(.password), asked < 3 else {
            let error: SSHError = hop.credentials.isEmpty && asked == 0 ? .noCredentials : .authenticationFailed
            failure.set(error)
            // failing (not succeeding with nil) is what ends the handshake.
            nextChallengePromise.fail(error)
            return
        }
        asked += 1
        let (handlers, index, endpoint, failure) = (handlers, index, hop.endpoint, failure)
        Task {
            guard let password = await handlers.askPassword(index, endpoint) else {
                failure.set(.cancelled)
                nextChallengePromise.fail(SSHError.cancelled)
                return
            }
            nextChallengePromise.succeed(
                .init(username: endpoint.username, serviceName: "", offer: .password(.init(password: password))))
        }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let (handlers, index, endpoint, failure) = (handlers, index, hop.endpoint, failure)
        let key = try? SSHPublicKey(hostKey)
        Task {
            if let key, await handlers.verifyHostKey(index, endpoint, key) {
                validationCompletePromise.succeed()
            } else {
                failure.set(.hostKeyRejected)
                validationCompletePromise.fail(SSHError.hostKeyRejected)
            }
        }
    }
}

final class AuthWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>
    private let failure: LockedBox<SSHError>
    private var done = false

    init(promise: EventLoopPromise<Void>, failure: LockedBox<SSHError>) {
        self.promise = promise
        self.failure = failure
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { finish(nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        sshLog.error("connection error: \(String(describing: error), privacy: .public)")
        finish(failure.value ?? SSHError.wrap(error))
        context.close(promise: nil)
    }

    func closed() { finish(failure.value ?? SSHError.disconnected) }

    private func finish(_ error: SSHError?) {
        guard !done else { return }
        done = true
        if let error { promise.fail(error) } else { promise.succeed() }
    }
}
