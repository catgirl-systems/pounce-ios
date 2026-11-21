import AppIntents
import Foundation
import PounceCore

// MARK: - keys

struct GetPublicKeyIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Get Public Key"
    static let description = IntentDescription(
        "Returns an SSH key's public half as an authorized_keys line. The private key never leaves pounce.",
        categoryName: "Keys")

    @Parameter(title: "Key") var key: IdentityEntity

    static var parameterSummary: some ParameterSummary { Summary("Get the public key of \(\.$key)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let identity = AppModel.shared.identity(key.id) else { throw IntentError.missing }
        return .result(value: identity.publicKey)
    }
}

/// signs in with what the host already has, so the first key still has to
/// get there some other way (like a password).
struct InstallPublicKeyIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Install Public Key on Host"
    static let description = IntentDescription(
        "Adds an SSH key to ~/.ssh/authorized_keys on a host, unless it's there already. Signs in with the host's current key or saved password.",
        categoryName: "Keys")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Key") var key: IdentityEntity
    @Parameter(title: "Host") var host: HostEntity
    @Parameter(
        title: "Use for This Host", description: "Signs in to the host with this key from now on.", default: false)
    var assign: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$key) on \(\.$host)") { \.$assign }
    }

    // the key arrives on stdin so it needs no quoting, and `sh -c` keeps it
    // working when the login shell isn't posix.
    private static let script = """
        sh -c 'umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && IFS= read -r key && \
        if grep -qxF "$key" ~/.ssh/authorized_keys; then echo present; \
        else printf "%s\\n" "$key" >> ~/.ssh/authorized_keys && echo added; fi'
        """

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard let identity = app.identity(key.id), let saved = app.host(host.id) else { throw IntentError.missing }
        try await unlockSecrets(for: [saved])
        let result = await CommandRunner.run(
            Self.script, on: saved, input: Data((identity.publicKey + "\n").utf8), timeout: 30)
        if let failure = result.failure { throw IntentError.failed(failure) }
        guard result.exitStatus == 0 else {
            throw IntentError.failed("Couldn't update authorized_keys: \(result.text)")
        }
        // read again: connecting stamped the host, and sync may have changed it.
        if assign, var current = app.host(saved.id) {
            current.identityID = identity.id
            app.save(current)
        }
        let added = result.output.contains("added")
        return .result(
            dialog: added
                ? "Installed “\(identity.name)” on \(saved.displayName)."
                : "\(saved.displayName) already has “\(identity.name)”.")
    }
}

// MARK: - sync

struct SyncNowIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Sync pounce"
    static let description = IntentDescription(
        "Syncs hosts, tunnels, snippets and known hosts with your pounce-sync server now, and returns how many changes went each way.",
        categoryName: "Sync")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let engine = AppModel.shared.sync.engine else { throw IntentError.syncOff }
        try await unlockSecrets()
        do {
            let report = try await engine.sync()
            let summary = "Received \(report.received), sent \(report.sent)."
            return .result(value: summary, dialog: "\(summary)")
        } catch {
            throw IntentError.failed(error.localizedDescription)
        }
    }
}
