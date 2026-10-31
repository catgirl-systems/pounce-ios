import Foundation
import Observation
import PounceCore

/// tunnels on the same host share one connection, which closes when the last
/// of them stops.
@MainActor @Observable final class TunnelManager {
    enum Status: Equatable {
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: [Tunnel.ID: Status] = [:]
    @ObservationIgnored private var forwards: [Tunnel.ID: PortForward] = [:]
    @ObservationIgnored private var connections: [Host.ID: SSHConnection] = [:]
    @ObservationIgnored private var pending: [Host.ID: Task<SSHConnection, any Error>] = [:]
    @ObservationIgnored private var starts: [Tunnel.ID: Task<Void, Never>] = [:]
    /// tunnels that were running when their connection dropped.
    @ObservationIgnored private var dropped: Set<Tunnel.ID> = []

    var hasRunning: Bool { runningCount > 0 }

    var runningCount: Int { status.values.filter { if case .running = $0 { true } else { false } }.count }

    func isOn(_ tunnel: Tunnel) -> Bool {
        switch status[tunnel.id] {
        case .starting, .running: true
        default: false
        }
    }

    func traffic(_ tunnel: Tunnel) -> TrafficCounter? { forwards[tunnel.id]?.traffic }

    func start(_ tunnel: Tunnel) {
        guard !isOn(tunnel), let host = AppModel.shared.host(tunnel.hostID) else { return }
        status[tunnel.id] = .starting
        starts[tunnel.id] = Task {
            do {
                let connection = try await connection(for: host)
                let forward: PortForward =
                    switch tunnel.kind {
                    case .local:
                        try await connection.startLocalForward(
                            bindPort: tunnel.bindPort, targetHost: tunnel.targetHost, targetPort: tunnel.targetPort)
                    case .remote:
                        try await connection.startRemoteForward(
                            bindPort: tunnel.bindPort, targetHost: tunnel.targetHost, targetPort: tunnel.targetPort)
                    case .dynamic:
                        try await connection.startDynamicForward(bindPort: tunnel.bindPort)
                    }
                guard !Task.isCancelled else {
                    forward.close()
                    return
                }
                forwards[tunnel.id] = forward
                status[tunnel.id] = .running(port: forward.port)
            } catch {
                guard !Task.isCancelled else { return }
                status[tunnel.id] = .failed(error.localizedDescription)
                closeIdleConnection(for: tunnel.hostID)
            }
            starts[tunnel.id] = nil
        }
    }

    func stop(_ tunnel: Tunnel) {
        dropped.remove(tunnel.id)
        starts.removeValue(forKey: tunnel.id)?.cancel()
        forwards.removeValue(forKey: tunnel.id)?.close()
        status[tunnel.id] = nil
        closeIdleConnection(for: tunnel.hostID)
    }

    func stopAll() {
        for tunnel in AppModel.shared.savedTunnels { stop(tunnel) }
        for connection in connections.values { connection.close() }
        connections = [:]
    }

    func restartDropped() {
        for tunnel in AppModel.shared.savedTunnels where dropped.contains(tunnel.id) {
            status[tunnel.id] = nil
            start(tunnel)
        }
        dropped = []
    }

    private func connection(for host: Host) async throws -> SSHConnection {
        if let existing = connections[host.id], existing.isActive { return existing }
        if let task = pending[host.id] { return try await task.value }
        let task = Task { try await AppModel.shared.connect(host) }
        pending[host.id] = task
        defer { pending[host.id] = nil }
        let connection = try await task.value
        connections[host.id] = connection
        watch(connection, host: host.id)
        return connection
    }

    /// marks a host's tunnels as failed when its connection drops.
    private func watch(_ connection: SSHConnection, host: Host.ID) {
        Task {
            await connection.waitUntilClosed()
            guard connections[host] === connection else { return }
            connections[host] = nil
            for tunnel in AppModel.shared.savedTunnels where tunnel.hostID == host && forwards[tunnel.id] != nil {
                forwards[tunnel.id] = nil
                dropped.insert(tunnel.id)
                status[tunnel.id] = .failed("The connection was lost.")
            }
        }
    }

    private func closeIdleConnection(for host: Host.ID) {
        let inUse = AppModel.shared.savedTunnels.contains { $0.hostID == host && isOn($0) }
        if !inUse, let connection = connections.removeValue(forKey: host) { connection.close() }
    }
}
