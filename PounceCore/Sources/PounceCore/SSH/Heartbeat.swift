import NIOCore
import NIOSSH

extension SSHConnection {
    /// like openssh's `ServerAliveInterval 20` and `ServerAliveCountMax 3`.
    public static let heartbeatInterval: Duration = .seconds(20)
    static let heartbeatMisses = 3

    func ping(timeout: Duration) async throws(SSHError) {
        let _: Void = try await withHandler { ssh, loop in
            let promise = loop.makePromise(of: Void.self)
            ssh.sendKeepAlive(promise: promise)
            let timer = loop.scheduleTask(in: .seconds(timeout.components.seconds)) {
                promise.fail(SSHError.timedOut)
            }
            promise.futureResult.whenComplete { _ in timer.cancel() }
            return promise.futureResult
        }
    }

    /// keeps nat routers and firewalls from dropping a quiet connection, and closes
    /// it once the server stops answering so readers see the drop and reconnect.
    func startHeartbeat() {
        let task = Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: SSHConnection.heartbeatInterval)
                guard let self, self.isActive else { return }
                do {
                    try await self.ping(timeout: .seconds(10))
                    missed = 0
                } catch {
                    missed += 1
                    sshLog.info("keepalive unanswered (\(missed, privacy: .public))")
                    if missed >= SSHConnection.heartbeatMisses {
                        sshLog.error("server stopped answering keepalives, closing")
                        self.close()
                        return
                    }
                }
            }
        }
        channel.closeFuture.whenComplete { _ in task.cancel() }
    }
}
