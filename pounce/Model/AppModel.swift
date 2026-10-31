import Foundation
import Observation
import PounceCore
import SwiftUI
import os

let log = Logger(subsystem: "catgirl.engineering.pounce", category: "app")

/// a singleton so app intents can reach it without a view hierarchy.
@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    private(set) var data: AppData {
        didSet { if data != oldValue { store.save(data) } }
    }
    var notice: Notice?

    let sessions = SessionManager()
    let tunnels = TunnelManager()
    let prompts = PromptCenter()
    @ObservationIgnored let liveActivity = LiveActivityController()
    @ObservationIgnored let keeper = BackgroundKeeper()

    @ObservationIgnored private let store = Store()

    private init() {
        data = store.load()
        liveActivity.watch()
        keeper.watch()
    }

    var hosts: [Host] { data.hosts }
    var identities: [Identity] { data.identities }
    var snippets: [Snippet] { data.snippets }
    var savedTunnels: [Tunnel] { data.tunnels }
    var knownHosts: [KnownHost] { data.knownHosts }

    func host(_ id: UUID?) -> Host? { data.hosts[id: id] }
    func identity(_ id: UUID?) -> Identity? { data.identities[id: id] }

    var hasOpenConnections: Bool { !sessions.sessions.isEmpty || tunnels.hasRunning }

    // MARK: - notices

    func notify(_ title: String, subtitle: String? = nil) {
        notice = Notice(title: title, subtitle: subtitle)
    }

    func fail(_ message: String, subtitle: String? = nil) {
        notice = Notice(title: message, subtitle: subtitle, isError: true)
    }

    func copy(_ text: String, notice title: String, subtitle: String? = nil) {
        UIPasteboard.general.string = text
        notify(title, subtitle: subtitle)
    }

    // MARK: - hosts

    func save(_ host: Host) { data.hosts[id: host.id] = host }

    func delete(_ host: Host) {
        var data = data
        data.hosts.removeAll { $0.id == host.id }
        // hosts that jumped through it now connect directly.
        for index in data.hosts.indices { data.hosts[index].jumpHostIDs.removeAll { $0 == host.id } }
        for tunnel in data.tunnels where tunnel.hostID == host.id { tunnels.stop(tunnel) }
        data.tunnels.removeAll { $0.hostID == host.id }
        self.data = data
        Keychain.deletePassword(for: host.id)
    }

    func toggleFavorite(_ host: Host) { data.hosts[id: host.id]?.isFavorite.toggle() }

    func markConnected(_ host: Host) { data.hosts[id: host.id]?.lastConnected = .now }

    var tags: [String] { Array(Set(data.hosts.flatMap(\.tags))).sorted() }

    @discardableResult
    func importConfig(_ text: String) -> Int {
        var data = data
        defer { self.data = data }
        let entries = SSHConfigImport.parse(text)
        var byAlias: [String: UUID] = [:]
        var added: [Host] = []
        for entry in entries {
            // match by label so re-importing updates instead of duplicating.
            let existing = data.hosts.first { $0.label == entry.alias }
            var host =
                existing
                ?? Host(label: entry.alias, hostname: entry.hostname, username: entry.user ?? "root")
            host.hostname = entry.hostname
            host.port = entry.port
            if let user = entry.user { host.username = user }
            byAlias[entry.alias] = host.id
            added.append(host)
        }
        for (index, entry) in entries.enumerated() {
            added[index].jumpHostIDs = entry.proxyJump.compactMap { spec in
                if let id = byAlias[spec] { return id }
                // a jump given as `user@host:port` becomes its own host.
                guard let endpoint = QuickConnect.parse(spec, defaultUser: added[index].username) else { return nil }
                let jump = Host(endpoint: endpoint)
                added.append(jump)
                return jump.id
            }
        }
        for host in added { data.hosts[id: host.id] = host }
        for (index, entry) in entries.enumerated() {
            for forward in entry.forwards
            where !data.tunnels.contains(where: {
                $0.hostID == added[index].id && $0.kind == forward.kind && $0.bindPort == forward.bindPort
            }) {
                data.tunnels.append(
                    Tunnel(
                        hostID: added[index].id, kind: forward.kind, bindPort: forward.bindPort,
                        targetHost: forward.targetHost, targetPort: forward.targetPort))
            }
        }
        return entries.count
    }

    // MARK: - identities

    func addIdentity(_ material: PrivateKeyMaterial, name: String, requireBiometry: Bool) throws -> Identity {
        let publicKey = try material.publicKey
        // secure enclave keys enforce biometry inside the enclave instead.
        let gated = requireBiometry && material.kind != .secureEnclaveP256
        let identity = Identity(
            name: name.isEmpty ? (material.comment.isEmpty ? publicKey.algorithm : material.comment) : name,
            kind: material.kind, publicKey: publicKey.authorizedKeysLine, requiresBiometry: requireBiometry)
        try Keychain.save(material, for: identity.id, requireBiometry: gated)
        data.identities.append(identity)
        return identity
    }

    func rename(_ identity: Identity, to name: String) { data.identities[id: identity.id]?.name = name }

    func setIcon(_ identity: Identity, to icon: String?) { data.identities[id: identity.id]?.icon = icon }

    func delete(_ identity: Identity) {
        Keychain.deleteKey(for: identity.id)
        var data = data
        data.identities.removeAll { $0.id == identity.id }
        for index in data.hosts.indices where data.hosts[index].identityID == identity.id {
            data.hosts[index].identityID = nil
        }
        self.data = data
    }

    // MARK: - snippets and tunnels

    func save(_ snippet: Snippet) { data.snippets[id: snippet.id] = snippet }

    func delete(_ snippet: Snippet) {
        var data = data
        data.snippets.removeAll { $0.id == snippet.id }
        for index in data.hosts.indices where data.hosts[index].startupSnippetID == snippet.id {
            data.hosts[index].startupSnippetID = nil
        }
        self.data = data
    }

    func snippet(_ id: UUID?) -> Snippet? { data.snippets[id: id] }

    func moveSnippets(from source: IndexSet, to destination: Int) {
        data.snippets.move(fromOffsets: source, toOffset: destination)
    }

    func save(_ tunnel: Tunnel) { data.tunnels[id: tunnel.id] = tunnel }

    func delete(_ tunnel: Tunnel) {
        tunnels.stop(tunnel)
        data.tunnels.removeAll { $0.id == tunnel.id }
    }

    // MARK: - known hosts

    func forget(_ known: KnownHost) {
        data.knownHosts.removeAll { $0 == known }
    }

    /// called by the live activity's button.
    func disconnectAll() {
        sessions.closeAll()
        tunnels.stopAll()
    }

    func eraseAll() {
        disconnectAll()
        Keychain.deleteAll()
        data = AppData()
    }

    // MARK: - connecting

    /// asks the user about unknown host keys and missing passwords along the way.
    func connect(
        _ host: Host, interactive: Bool = true, progress: @escaping @Sendable (Int, ConnectStage) -> Void = { _, _ in }
    ) async throws -> SSHConnection {
        let chain = try jumpChain(for: host)
        var hops: [SSHHop] = []
        for hop in chain {
            hops.append(SSHHop(endpoint: hop.endpoint, credentials: try await credentials(for: hop)))
        }
        let hostIDs = chain.map(\.id)
        let handlers = SSHConnectHandlers(
            verifyHostKey: { _, endpoint, key in
                await AppModel.shared.verify(key, for: endpoint, interactive: interactive)
            },
            askPassword: { index, endpoint in
                guard interactive else { return nil }
                return await AppModel.shared.askPassword(for: endpoint, hostID: hostIDs[index])
            },
            progress: progress)
        let connection = try await SSHConnection.connect(hops, handlers: handlers)
        markConnected(host)
        return connection
    }

    /// ends with the host itself.
    func jumpChain(for host: Host) throws -> [Host] {
        var chain: [Host] = []
        var visiting: Set<UUID> = [host.id]
        // jump hosts can have jump hosts of their own, like `ProxyJump`.
        func walk(_ ids: [UUID]) throws {
            for id in ids {
                guard let jump = self.host(id) else { continue }
                guard visiting.insert(id).inserted else { throw ConnectError.jumpLoop }
                try walk(jump.jumpHostIDs)
                chain.append(jump)
            }
        }
        try walk(host.jumpHostIDs)
        return chain + [host]
    }

    enum ConnectError: LocalizedError {
        case jumpLoop
        var errorDescription: String? { "The jump hosts for this host go round in a loop." }
    }

    /// hosts without their own key (like quick connects) try every key that
    /// doesn't need face id, the way an ssh agent would.
    private func credentials(for host: Host) async throws -> [SSHCredential] {
        let identities =
            identity(host.identityID).map { [$0] } ?? Array(data.identities.filter { !$0.requiresBiometry }.prefix(3))
        let keys = identities.map { ($0.id, "Sign in to \(host.displayName) with “\($0.name)”") }
        let hostID = host.id
        // off the main actor: keychain reads can block on face id.
        return try await Task.detached {
            let credentials: [SSHCredential] = try keys.compactMap { id, reason in
                try Keychain.key(for: id, reason: reason).map { .privateKey(try $0.sshPrivateKey()) }
            }
            return credentials + (Keychain.password(for: hostID).map { [.password($0)] } ?? [])
        }.value
    }

    private func verify(_ key: SSHPublicKey, for endpoint: SSHEndpoint, interactive: Bool) async -> Bool {
        let status = data.status(of: key, host: endpoint.host, port: endpoint.port)
        if status == .trusted { return true }
        guard interactive else { return false }
        let previous: KnownHost? = if case .changed(let previous) = status { previous } else { nil }
        let answer = await prompts.ask(.hostKey(endpoint: endpoint, key: key, previous: previous))
        guard answer == .accept else { return false }
        data.trust(key, host: endpoint.host, port: endpoint.port)
        return true
    }

    private func askPassword(for endpoint: SSHEndpoint, hostID: UUID) async -> String? {
        let saved = host(hostID) != nil
        guard case .password(let password, let save) = await prompts.ask(.password(endpoint: endpoint, canSave: saved))
        else { return nil }
        if save, saved {
            do { try Keychain.savePassword(password, for: hostID) } catch { log.error("couldn't save password") }
        }
        return password
    }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var isError = false

    var symbol: String { isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }
    var tint: SwiftUI.Color { isError ? .red : .green }
}

extension Array where Element: Identifiable {
    /// setting replaces or appends the element; setting nil removes it.
    subscript(id id: Element.ID?) -> Element? {
        get { first { $0.id == id } }
        set {
            guard let newValue else { return removeAll { $0.id == id } }
            if let index = firstIndex(where: { $0.id == newValue.id }) {
                self[index] = newValue
            } else {
                append(newValue)
            }
        }
    }
}

extension Host {
    init(endpoint: SSHEndpoint) {
        self.init(hostname: endpoint.host, port: endpoint.port, username: endpoint.username)
    }
}
