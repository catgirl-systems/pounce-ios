import AppIntents
import Foundation
import PounceCore

struct OpenSessionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Open SSH Session"
    static let description = IntentDescription(
        "Opens a terminal on a host in pounce, and can type a snippet once it connects.", categoryName: "Sessions")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Snippet", description: "Typed into the terminal once it connects, in place of the host's own.")
    var snippet: SnippetEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open a session on \(\.$host)") { \.$snippet }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        guard UserDefaults.allowsShortcuts else { throw IntentError.shortcutsOff }
        let session = AppModel.shared.sessions.open(saved, startup: AppModel.shared.snippet(snippet?.id))
        return .result(value: SessionEntity(session))
    }
}

struct QuickConnectIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Quick Connect"
    static let description = IntentDescription(
        "Opens a terminal on user@host:port without saving it as a host.", categoryName: "Sessions")
    static let openAppWhenRun = true

    @Parameter(
        title: "Address",
        inputOptions: String.IntentInputOptions(keyboardType: .URL, capitalizationType: .none, autocorrect: false))
    var address: String

    static var parameterSummary: some ParameterSummary { Summary("Connect to \(\.$address)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> {
        guard UserDefaults.allowsShortcuts else { throw IntentError.shortcutsOff }
        guard let endpoint = QuickConnect.parse(address) else {
            throw IntentError.failed("“\(address)” isn't an address like user@host or user@host:port.")
        }
        let session = AppModel.shared.sessions.open(Host(endpoint: endpoint))
        return .result(value: SessionEntity(session))
    }
}

/// types into the terminal, like tapping the snippet in the key bar.
struct SendSnippetToSessionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Send Snippet to Session"
    static let description = IntentDescription(
        "Types a snippet into an open session. Values fill its {{placeholders}} in the order they first appear.",
        categoryName: "Sessions")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Snippet") var snippet: SnippetEntity
    @Parameter(title: "Session") var session: SessionEntity
    @Parameter(title: "Values", default: []) var values: [String]

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$snippet) to \(\.$session)") { \.$values }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let open = AppModel.shared.sessions.sessions[id: session.id],
            let snippet = AppModel.shared.snippet(snippet.id)
        else { throw IntentError.missing }
        // typing into a signed-in shell is as good as the keys themselves.
        try await unlockSecrets()
        guard open.state == .connected else {
            throw IntentError.failed("“\(open.displayTitle)” isn't connected.")
        }
        let placeholders = snippet.placeholders
        guard values.count >= placeholders.count else {
            throw IntentError.failed("“\(snippet.name)” needs values for \(placeholders.formatted()).")
        }
        open.run(snippet, values: Dictionary(uniqueKeysWithValues: zip(placeholders, values)))
        return .result()
    }
}

struct GetOpenSessionsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Get Open Sessions"
    static let description = IntentDescription("Returns the terminals open in pounce.", categoryName: "Sessions")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SessionEntity]> {
        .result(value: AppModel.shared.sessions.sessions.map(SessionEntity.init))
    }
}

struct CloseSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Session"
    static let description = IntentDescription("Closes an open terminal.", categoryName: "Sessions")

    @Parameter(title: "Session") var session: SessionEntity

    static var parameterSummary: some ParameterSummary { Summary("Close \(\.$session)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let open = AppModel.shared.sessions.sessions[id: session.id] else { throw IntentError.missing }
        AppModel.shared.sessions.close(open)
        return .result()
    }
}

struct DisconnectAllShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect Everything"
    static let description = IntentDescription(
        "Closes every session and stops every tunnel in pounce.", categoryName: "Sessions")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = AppModel.shared.sessions.sessions.count + AppModel.shared.tunnels.runningCount
        AppModel.shared.disconnectAll()
        return .result(dialog: count == 0 ? "Nothing was connected." : "Disconnected.")
    }
}
