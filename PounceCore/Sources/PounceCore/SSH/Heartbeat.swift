import NIOCore
import NIOSSH

extension SSHConnection {
    func ping() async throws(SSHError) {
        try await withHandler { ssh, loop in
            let promise = loop.makePromise(of: Void.self)
            ssh.sendKeepAlive(promise: promise)
            let timer = loop.scheduleTask(in: .seconds(10)) {
                promise.fail(SSHError.timedOut)
            }
            promise.futureResult.whenComplete { _ in timer.cancel() }
            return promise.futureResult
        }
    }

    /// like openssh's `ServerAliveInterval 20` and `ServerAliveCountMax 3`: keeps nat routers from
    /// dropping a quiet connection, and closes it once the server stops answering so readers reconnect
    func startHeartbeat() {
        let task = Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.isActive else { return }
                do {
                    try await self.ping()
                    missed = 0
                } catch {
                    missed += 1
                    sshLog.info("keepalive unanswered (\(missed, privacy: .public))")
                    if missed >= 3 {
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
