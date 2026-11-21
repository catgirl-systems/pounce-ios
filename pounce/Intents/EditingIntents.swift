import AppIntents
import Foundation
import PounceCore

struct CreateHostIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Create Host"
    static let description = IntentDescription("Adds a host to pounce and returns it.", categoryName: "Hosts")

    @Parameter(
        title: "Hostname",
        inputOptions: String.IntentInputOptions(keyboardType: .URL, capitalizationType: .none, autocorrect: false))
    var hostname: String
    @Parameter(
        title: "User", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var username: String
    @Parameter(title: "Port", default: 22, inclusiveRange: (1, 65535)) var port: Int
    @Parameter(title: "Name") var label: String?
    @Parameter(title: "Key") var key: IdentityEntity?
    @Parameter(title: "Tags", default: []) var tags: [String]
    @Parameter(title: "Jump Hosts", default: []) var jumpHosts: [HostEntity]
    @Parameter(title: "Favorite", default: false) var isFavorite: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$username) at \(\.$hostname)") {
            \.$port
            \.$label
            \.$key
            \.$tags
            \.$jumpHosts
            \.$isFavorite
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<HostEntity> {
        let app = AppModel.shared
        let hostname = hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty else { throw IntentError.failed("The hostname is empty.") }
        let host = Host(
            label: label ?? "", hostname: hostname, port: port, username: username,
            identityID: app.identity(key?.id)?.id, jumpHostIDs: jumpHosts.compactMap { app.host($0.id)?.id },
            tags: tags.cleanedTags, isFavorite: isFavorite)
        app.save(host)
        return .result(value: HostEntity(host))
    }
}

struct EditHostIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Edit Host"
    static let description = IntentDescription(
        "Changes a host's details. Anything left empty stays as it is.", categoryName: "Hosts")

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Name") var label: String?
    @Parameter(
        title: "Hostname",
        inputOptions: String.IntentInputOptions(keyboardType: .URL, capitalizationType: .none, autocorrect: false))
    var hostname: String?
    @Parameter(title: "Port", inclusiveRange: (1, 65535)) var port: Int?
    @Parameter(
        title: "User", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var username: String?
    @Parameter(title: "Key") var key: IdentityEntity?
    @Parameter(title: "Jump Hosts") var jumpHosts: [HostEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Edit \(\.$host)") {
            \.$label
            \.$hostname
            \.$port
            \.$username
            \.$key
            \.$jumpHosts
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<HostEntity> {
        let app = AppModel.shared
        guard var saved = app.host(host.id) else { throw IntentError.missing }
        if let label { saved.label = label }
        if let hostname = hostname?.trimmingCharacters(in: .whitespaces), !hostname.isEmpty {
            saved.hostname = hostname
        }
        if let port { saved.port = port }
        if let username { saved.username = username }
        if let key = app.identity(key?.id) { saved.identityID = key.id }
        if let jumpHosts {
            saved.jumpHostIDs = jumpHosts.compactMap { app.host($0.id)?.id }.filter { $0 != saved.id }
            if (try? app.jumpChain(for: saved)) == nil {
                throw IntentError.failed("Those jump hosts would go round in a loop.")
            }
        }
        app.save(saved)
        return .result(value: HostEntity(saved))
    }
}

struct AddTagsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Add Tags to Hosts"
    static let description = IntentDescription("Tags hosts, for grouping and finding them.", categoryName: "Hosts")

    @Parameter(title: "Tags") var tags: [String]
    @Parameter(title: "Hosts") var hosts: [HostEntity]

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$tags) to \(\.$hosts)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HostEntity]> {
        .result(value: updateHosts(hosts) { $0.tags = ($0.tags + tags).cleanedTags })
    }
}

struct RemoveTagsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Remove Tags from Hosts"
    static let description = IntentDescription("Takes tags off hosts.", categoryName: "Hosts")

    @Parameter(title: "Tags") var tags: [String]
    @Parameter(title: "Hosts") var hosts: [HostEntity]

    static var parameterSummary: some ParameterSummary { Summary("Remove \(\.$tags) from \(\.$hosts)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HostEntity]> {
        .result(
            value: updateHosts(hosts) { host in
                host.tags.removeAll { tag in tags.contains { $0.equalsIgnoringCase(tag) } }
            })
    }
}

struct SetFavoriteIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Set Favorite"
    static let description = IntentDescription(
        "Adds hosts to Favorites, or takes them off.", categoryName: "Hosts")

    @Parameter(title: "Favorite", default: true) var isFavorite: Bool
    @Parameter(title: "Hosts") var hosts: [HostEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Set favorite to \(\.$isFavorite) for \(\.$hosts)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HostEntity]> {
        .result(value: updateHosts(hosts) { $0.isFavorite = isFavorite })
    }
}

struct DeleteHostIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Delete Host"
    static let description = IntentDescription(
        "Deletes a host, its tunnels and its saved password, after asking.", categoryName: "Hosts")

    @Parameter(title: "Host") var host: HostEntity

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$host)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        try await requestConfirmation(
            dialog: "Delete “\(saved.displayName)” from pounce? Its tunnels and saved password are deleted too.")
        AppModel.shared.delete(saved)
        return .result()
    }
}

struct ImportSSHConfigIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Import SSH Config"
    static let description = IntentDescription(
        "Adds the hosts, jump hosts and forwards from ~/.ssh/config text. Hosts already imported under the same name are updated.",
        categoryName: "Hosts")

    @Parameter(title: "Config", inputOptions: String.IntentInputOptions(multiline: true)) var config: String

    static var parameterSummary: some ParameterSummary { Summary("Import \(\.$config) as hosts") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HostEntity]> {
        let aliases = Set(SSHConfigImport.parse(config).map(\.alias))
        guard !aliases.isEmpty else { throw IntentError.failed("That text has no Host entries.") }
        AppModel.shared.importConfig(config)
        return .result(value: AppModel.shared.hosts.filter { aliases.contains($0.label) }.map(HostEntity.init))
    }
}

@MainActor private func updateHosts(_ entities: [HostEntity], _ change: (inout Host) -> Void) -> [HostEntity] {
    entities.compactMap { entity in
        guard var host = AppModel.shared.host(entity.id) else { return nil }
        change(&host)
        AppModel.shared.save(host)
        return HostEntity(host)
    }
}

extension [String] {
    fileprivate var cleanedTags: [String] {
        var seen: [String] = []
        for tag in map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
            if !seen.contains(where: { $0.equalsIgnoringCase(tag) }) { seen.append(tag) }
        }
        return seen
    }
}

struct CreateSnippetIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Create Snippet"
    static let description = IntentDescription(
        "Adds a snippet. Use {{name}} for values to fill in when it runs.", categoryName: "Snippets")

    @Parameter(title: "Name") var name: String
    @Parameter(
        title: "Command",
        inputOptions: String.IntentInputOptions(capitalizationType: .none, multiline: true, autocorrect: false))
    var command: String
    @Parameter(
        title: "Press Return", description: "Runs it right away when sent to a session.", default: true)
    var runImmediately: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create snippet \(\.$name) running \(\.$command)") { \.$runImmediately }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SnippetEntity> {
        let snippet = Snippet(name: name, command: command, runImmediately: runImmediately)
        AppModel.shared.save(snippet)
        return .result(value: SnippetEntity(snippet))
    }
}

struct DeleteSnippetIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Delete Snippet"
    static let description = IntentDescription("Deletes a snippet after asking.", categoryName: "Snippets")

    @Parameter(title: "Snippet") var snippet: SnippetEntity

    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$snippet)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let saved = AppModel.shared.snippet(snippet.id) else { throw IntentError.missing }
        try await requestConfirmation(dialog: "Delete the snippet “\(saved.name)”?")
        AppModel.shared.delete(saved)
        return .result()
    }
}

enum NewKeyKind: String, AppEnum {
    case ed25519, secureEnclave

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Key Type"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .ed25519: DisplayRepresentation(title: "Ed25519", subtitle: "Kept in the Keychain"),
        .secureEnclave: DisplayRepresentation(
            title: "Secure Enclave P-256", subtitle: "Made inside this device's chip and can never leave it"),
    ]
}

struct GenerateKeyIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Generate SSH Key"
    static let description = IntentDescription(
        "Makes a new SSH key on this device and returns it. Get its public key to put it on a server.",
        categoryName: "Keys")

    @Parameter(title: "Name") var name: String
    @Parameter(title: "Type", default: .ed25519) var kind: NewKeyKind
    @Parameter(title: "Require Face ID", default: false) var requireBiometry: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Generate \(\.$kind) key \(\.$name)") { \.$requireBiometry }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IdentityEntity> {
        do {
            let material =
                switch kind {
                case .ed25519: PrivateKeyMaterial.generateEd25519(comment: name)
                case .secureEnclave:
                    try PrivateKeyMaterial.generateSecureEnclaveP256(comment: name, requireBiometry: requireBiometry)
                }
            let identity = try AppModel.shared.addIdentity(material, name: name, requireBiometry: requireBiometry)
            return .result(value: IdentityEntity(identity))
        } catch {
            throw IntentError.failed("Couldn't make the key: \(error.localizedDescription)")
        }
    }
}
