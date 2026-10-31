import AppIntents
import Foundation
import PounceCore

struct HostEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = HostQuery()

    let id: UUID
    let name: String
    let address: String

    init(_ host: Host) {
        id = host.id
        name = host.displayName
        address = host.address
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(address)")
    }
}

struct HostQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        AppModel.shared.hosts.filter { identifiers.contains($0.id) }.map(HostEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [HostEntity] {
        AppModel.shared.hosts
            .filter { $0.displayName.localizedCaseInsensitiveContains(string) || $0.hostname.contains(string) }
            .map(HostEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [HostEntity] {
        AppModel.shared.hosts.map(HostEntity.init)
    }
}

struct TunnelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel"
    static let defaultQuery = TunnelQuery()

    let id: UUID
    let name: String

    init(_ tunnel: Tunnel) {
        id = tunnel.id
        name = tunnel.displayName
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TunnelQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [TunnelEntity] {
        AppModel.shared.savedTunnels.filter { identifiers.contains($0.id) }.map(TunnelEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [TunnelEntity] {
        AppModel.shared.savedTunnels.map(TunnelEntity.init)
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case missing
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missing: "That host or tunnel no longer exists in pounce."
        case .failed(let message): "\(message)"
        }
    }
}

/// works without opening the app, for hosts whose key is already trusted.
struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run SSH Command"
    static let description = IntentDescription("Runs a command on a host and returns its output.")

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var command: String

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command) on \(\.$host)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        do {
            // not interactive: an unknown host key fails instead of asking.
            let connection = try await AppModel.shared.connect(saved, interactive: false)
            defer { connection.close() }
            let result = try await connection.run(command)
            var output = String(decoding: result.stdout, as: UTF8.self)
            if output.isEmpty { output = String(decoding: result.stderr, as: UTF8.self) }
            output = output.trimmingCharacters(in: .newlines)
            let status = result.exitStatus.map { $0 == 0 ? "" : " (exit \($0))" } ?? ""
            return .result(value: output, dialog: "\(output.isEmpty ? "Done" : output)\(status)")
        } catch SSHError.hostKeyRejected {
            throw IntentError.failed("Connect to \(saved.displayName) in pounce once to trust its host key.")
        } catch {
            throw IntentError.failed(error.localizedDescription)
        }
    }
}

struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open SSH Session"
    static let description = IntentDescription("Opens a terminal on a host in pounce.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    static var parameterSummary: some ParameterSummary { Summary("Open a session on \(\.$host)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        AppModel.shared.sessions.open(saved)
        return .result()
    }
}

/// tunnels need the app in the foreground to keep running, so this opens it.
struct StartTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Tunnel"
    static let description = IntentDescription("Starts a saved port forward in pounce.")
    static let openAppWhenRun = true

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$tunnel)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = AppModel.shared.savedTunnels[id: tunnel.id] else { throw IntentError.missing }
        AppModel.shared.tunnels.start(saved)
        return .result()
    }
}

struct PounceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSessionIntent(), phrases: ["Open \(\.$host) in \(.applicationName)"],
            shortTitle: "Open Session", systemImageName: "terminal")
        AppShortcut(
            intent: RunCommandIntent(), phrases: ["Run a command with \(.applicationName)"],
            shortTitle: "Run Command", systemImageName: "apple.terminal")
        AppShortcut(
            intent: StartTunnelIntent(), phrases: ["Start \(\.$tunnel) in \(.applicationName)"],
            shortTitle: "Start Tunnel", systemImageName: "point.3.connected.trianglepath.dotted")
    }
}
