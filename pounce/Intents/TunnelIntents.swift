import AppIntents
import Foundation
import PounceCore
import UIKit

struct StartTunnelIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Start Tunnel"
    static let description = IntentDescription(
        "Starts a saved port forward and waits until it's listening. Returns the port it listens on. Opens pounce unless Stay Connected in Background is on.",
        categoryName: "Tunnels")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$tunnel)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let saved = AppModel.shared.savedTunnels[id: tunnel.id], let host = AppModel.shared.host(saved.hostID)
        else { throw IntentError.missing }
        try await unlockSecrets(for: [host])
        try await stayAliveForConnections()
        let port = try await startAndWait(saved)
        return .result(value: port, dialog: "\(saved.displayName) is listening on port \(port).")
    }
}

struct StopTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Tunnel"
    static let description = IntentDescription("Stops a running port forward.", categoryName: "Tunnels")

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$tunnel)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = AppModel.shared.savedTunnels[id: tunnel.id] else { throw IntentError.missing }
        AppModel.shared.tunnels.stop(saved)
        return .result()
    }
}

struct ToggleTunnelIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Toggle Tunnel"
    static let description = IntentDescription(
        "Starts a port forward when it's stopped, or stops it when it's running. Returns whether it's running now.",
        categoryName: "Tunnels")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    static var parameterSummary: some ParameterSummary { Summary("Toggle \(\.$tunnel)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let saved = AppModel.shared.savedTunnels[id: tunnel.id], let host = AppModel.shared.host(saved.hostID)
        else { throw IntentError.missing }
        if AppModel.shared.tunnels.isOn(saved) {
            AppModel.shared.tunnels.stop(saved)
            return .result(value: false)
        }
        try await unlockSecrets(for: [host])
        try await stayAliveForConnections()
        _ = try await startAndWait(saved)
        return .result(value: true)
    }
}

struct StopAllTunnelsIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop All Tunnels"
    static let description = IntentDescription("Stops every running port forward.", categoryName: "Tunnels")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.tunnels.stopAll()
        return .result()
    }
}

struct GetRunningTunnelsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Get Running Tunnels"
    static let description = IntentDescription(
        "Returns the port forwards that are listening now.", categoryName: "Tunnels")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TunnelEntity]> {
        .result(value: AppModel.shared.savedTunnels.map(TunnelEntity.init).filter(\.isRunning))
    }
}

@MainActor private func startAndWait(_ tunnel: Tunnel) async throws -> Int {
    let manager = AppModel.shared.tunnels
    // from the background nobody would see a host key or password prompt
    manager.start(tunnel, interactive: UIApplication.shared.applicationState == .active)
    let deadline = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < deadline {
        switch manager.status[tunnel.id] {
        case .running(let port): return port
        case .failed(let message): throw IntentError.failed(message)
        case nil: throw IntentError.failed("The tunnel stopped before it started.")
        case .starting: try await Task.sleep(for: .milliseconds(100))
        }
    }
    manager.stop(tunnel)
    throw IntentError.failed("The tunnel didn't start within a minute.")
}
