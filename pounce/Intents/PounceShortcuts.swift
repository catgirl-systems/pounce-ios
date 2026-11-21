import AppIntents

struct PounceShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .grayBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSessionIntent(),
            phrases: ["Open \(\.$host) in \(.applicationName)", "Connect to \(\.$host) with \(.applicationName)"],
            shortTitle: "Open Session", systemImageName: "terminal")
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run a command on \(\.$host) with \(.applicationName)", "Run a command with \(.applicationName)",
            ],
            shortTitle: "Run Command", systemImageName: "apple.terminal")
        AppShortcut(
            intent: RunSnippetOnHostIntent(),
            phrases: ["Run \(\.$snippet) with \(.applicationName)"],
            shortTitle: "Run Snippet", systemImageName: "text.alignleft")
        AppShortcut(
            intent: StartTunnelIntent(),
            phrases: ["Start \(\.$tunnel) in \(.applicationName)", "Open \(\.$tunnel) tunnel in \(.applicationName)"],
            shortTitle: "Start Tunnel", systemImageName: "point.3.connected.trianglepath.dotted")
        AppShortcut(
            intent: StopTunnelIntent(),
            phrases: ["Stop \(\.$tunnel) in \(.applicationName)"],
            shortTitle: "Stop Tunnel", systemImageName: "stop.circle")
        AppShortcut(
            intent: TestConnectionIntent(),
            phrases: ["Is \(\.$host) up in \(.applicationName)", "Test \(\.$host) with \(.applicationName)"],
            shortTitle: "Test Connection", systemImageName: "checkmark.seal")
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync \(.applicationName)"],
            shortTitle: "Sync", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(
            intent: DisconnectAllShortcutIntent(),
            phrases: ["Disconnect everything in \(.applicationName)", "Close all \(.applicationName) sessions"],
            shortTitle: "Disconnect All", systemImageName: "xmark.circle")
    }
}
