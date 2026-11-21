import Foundation
import Observation
import PounceCore
import SwiftUI
import Synchronization
import os

let log = Logger(category: "app")

// a singleton so app intents can reach it without a view hierarchy
@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    private(set) var data: AppData {
        didSet {
            guard data != oldValue else { return }
            store.save(data)
            sync.localChanged()
            if data.hosts != oldValue.hosts { spotlight.update() }
        }
    }
    var notice: Notice?
    /// notice banners on screen, bottom to top; only the last one shows the notice
    var noticeOwners: [UUID] = []
    var focus = HostFocus()

    let sessions = SessionManager()
    let tunnels = TunnelManager()
    let prompts = PromptCenter()
    let sync = SyncController()
    let lock = AppLock()
    @ObservationIgnored let liveActivity = LiveActivityController()
    @ObservationIgnored let keeper = BackgroundKeeper()
    @ObservationIgnored let spotlight = SpotlightIndex()

    @ObservationIgnored private let store = Store()

    private init() {
        data = store.load()
        // known hosts from before sync get their ids on load; keep them stable
        store.save(data)
        liveActivity.watch()
        keeper.watch()
        sync.start()
        spotlight.update()
        Task {
            // the focus may have changed while pounce wasn't running
            guard let filter = try? await HostFocusFilter.current else { return }
            focus = HostFocus(tags: filter.tags ?? [], keepFavorites: filter.keepFavorites)
        }
    }

    var hosts: [Host] { data.hosts }
    var identities: [Identity] { data.identities }
    var snippets: [Snippet] { data.snippets }
    var savedTunnels: [Tunnel] { data.tunnels }
    var knownHosts: [KnownHost] { data.knownHosts }

    func host(_ id: UUID?) -> Host? { data.hosts[id: id] }
    func identity(_ id: UUID?) -> Identity? { data.identities[id: id] }

    var hasOpenConnections: Bool { !sessions.sessions.isEmpty || tunnels.runningCount > 0 }

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

    func save(_ host: Host) { data.hosts[id: host.id] = host }

    func delete(_ host: Host) {
        var data = data
        data.hosts.removeAll { $0.id == host.id }
        for index in data.hosts.indices { data.hosts[index].jumpHostIDs.removeAll { $0 == host.id } }
        for tunnel in data.tunnels where tunnel.hostID == host.id { tunnels.stop(tunnel) }
        data.tunnels.removeAll { $0.hostID == host.id }
        self.data = data
        Keychain.deletePassword(for: host.id)
    }

    func toggleFavorite(_ host: Host) { data.hosts[id: host.id]?.isFavorite.toggle() }

    var tags: [String] { Array(Set(data.hosts.flatMap(\.tags))).sorted() }

    @discardableResult
    func importConfig(_ text: String) -> Int {
        var data = data
        defer { self.data = data }
        let entries = SSHConfigImport.parse(text)
        var byAlias: [String: UUID] = [:]
        var added: [Host] = []
        for entry in entries {
            // match by label so re-importing updates instead of duplicating
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
                // a jump given as `user@host:port` becomes its own host
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

    func addIdentity(_ material: PrivateKeyMaterial, name: String, requireBiometry: Bool) throws -> Identity {
        let publicKey = try material.publicKey
        // secure enclave keys enforce biometry inside the enclave instead
        let gated = requireBiometry && material.kind != .secureEnclaveP256
        let identity = Identity(
            name: name.isEmpty ? (material.comment.isEmpty ? publicKey.algorithm : material.comment) : name,
            kind: material.kind, publicKey: publicKey.authorizedKeysLine, requiresBiometry: requireBiometry)
        try Keychain.save(material, for: identity.id, requireBiometry: gated)
        data.identities.append(identity)
        return identity
    }

    func rename(_ identity: Identity, to name: String) { data.identities[id: identity.id]?.name = name }

    func setSyncsKey(_ on: Bool, for identity: Identity) async {
        guard on else {
            data.identities[id: identity.id]?.syncsKey = false
            return
        }
        do {
            let reason = "Sync “\(identity.name)” to your other devices"
            let material = try await Task.detached { try Keychain.key(for: identity.id, reason: reason) }.value
            guard let material else { return fail("The private key isn't on this \(Device.noun)") }
            // the switch goes first and uploads with the key (see `SyncEngine.upload`)
            data.identities[id: identity.id]?.syncsKey = true
            try await sync.uploadKey(material, identity: identity.id)
        } catch Keychain.Failure.cancelled {
        } catch {
            data.identities[id: identity.id]?.syncsKey = false
            fail("Couldn't sync the key", subtitle: error.localizedDescription)
        }
    }

    /// replaces a key a removed device may have kept; hosts move to the new key, and
    /// the old one stays until deleted since it's needed to install the new one
    func replaceKey(_ identity: Identity) throws -> Identity {
        let material = PrivateKeyMaterial.generateEd25519(comment: identity.name)
        let replacement = try addIdentity(
            material, name: "\(identity.name) (new)", requireBiometry: identity.requiresBiometry)
        var data = data
        for index in data.hosts.indices where data.hosts[index].identityID == identity.id {
            data.hosts[index].identityID = replacement.id
        }
        self.data = data
        return replacement
    }

    /// marks every key synced to the account: a removed device may have kept them
    func markSyncedSecretsExposed() {
        var data = data
        for index in data.identities.indices where data.identities[index].syncsKey {
            data.identities[index].exposedAt = .now
        }
        self.data = data
    }

    var exposedIdentities: [Identity] { data.identities.filter { $0.exposedAt != nil } }
    var hostsWithSyncedPasswords: [Host] { data.hosts.filter(\.syncsPassword) }

    func savePassword(_ password: String, for hostID: UUID) throws {
        try Keychain.savePassword(password, for: hostID)
        if host(hostID)?.syncsPassword == true { uploadPassword(password, for: hostID) }
    }

    /// on failure the host stops syncing its password, so the switch tells the truth
    func uploadPassword(_ password: String, for hostID: UUID) {
        Task {
            do {
                try await sync.uploadPassword(password, host: hostID)
            } catch {
                data.hosts[id: hostID]?.syncsPassword = false
                fail("Couldn't sync the password", subtitle: error.localizedDescription)
            }
        }
    }

    /// applies remote changes from the sync engine; returns the ids it had to skip
    func applySync(_ body: @Sendable (inout AppData) -> Set<Data>) -> Set<Data> {
        var data = data
        let skipped = body(&data)
        self.data = data
        return skipped
    }

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

    func forget(_ known: KnownHost) { data.knownHosts.removeAll { $0 == known } }

    func disconnectAll() {
        sessions.closeAll()
        tunnels.stopAll()
    }

    func eraseAll() {
        disconnectAll()
        // first, so no sync round sees the empty data; other devices keep theirs
        sync.turnOff()
        Keychain.deleteAll()
        data = AppData()
    }

    func connect(
        _ host: Host, interactive: Bool = true, progress: @escaping @Sendable (Int, ConnectStage) -> Void = { _, _ in }
    ) async throws -> SSHConnection {
        let chain = try jumpChain(for: host)
        var hops: [SSHHop] = []
        for hop in chain {
            hops.append(SSHHop(endpoint: hop.endpoint, credentials: try await credentials(for: hop)))
        }
        let hostIDs = chain.map(\.id)
        // passwords are saved only once the server accepts them, so a typo isn't stored and synced
        let accepted = Mutex<[UUID: String]>([:])
        let handlers = SSHConnectHandlers(
            verifyHostKey: { _, endpoint, key in
                await AppModel.shared.verify(key, for: endpoint, interactive: interactive)
            },
            askPassword: { index, endpoint in
                guard interactive else { return nil }
                let answer = await AppModel.shared.askPassword(for: endpoint, hostID: hostIDs[index])
                if let answer, answer.save { accepted.withLock { $0[hostIDs[index]] = answer.password } }
                return answer?.password
            },
            progress: progress)
        let connection = try await SSHConnection.connect(hops, handlers: handlers)
        for (hostID, password) in accepted.withLock({ $0 }) {
            do { try savePassword(password, for: hostID) } catch { log.error("couldn't save password") }
        }
        data.hosts[id: host.id]?.lastConnected = .now
        return connection
    }

    /// ends with the host itself
    func jumpChain(for host: Host) throws -> [Host] {
        var chain: [Host] = []
        var visiting: Set<UUID> = [host.id]
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

    /// hosts without their own key (like quick connects) try the first keys that
    /// don't need face id, the way an ssh agent would
    private func credentials(for host: Host) async throws -> [SSHCredential] {
        let identities =
            identity(host.identityID).map { [$0] } ?? Array(data.identities.filter { !$0.requiresBiometry }.prefix(3))
        let keys = identities.map { ($0.id, "Sign in to \(host.displayName) with “\($0.name)”") }
        let hostID = host.id
        // off the main actor: keychain reads can block on face id
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

    private func askPassword(for endpoint: SSHEndpoint, hostID: UUID) async -> (password: String, save: Bool)? {
        let saved = host(hostID) != nil
        guard case .password(let password, let save) = await prompts.ask(.password(endpoint: endpoint, canSave: saved))
        else { return nil }
        return (password, save && saved)
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

extension Host {
    init(endpoint: SSHEndpoint) {
        self.init(hostname: endpoint.host, port: endpoint.port, username: endpoint.username)
    }

    /// for connections that can't ask the user about an unknown host key
    var untrustedKeyHint: String { "Connect to \(displayName) in pounce once to trust its host key." }
}
