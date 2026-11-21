import AppIntents
import Foundation
import PounceCore

struct HostEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Host", numericFormat: "\(placeholder: .int) hosts")
    static let defaultQuery = HostQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Address") var address: String
    @Property(title: "Hostname") var hostname: String
    @Property(title: "Port") var port: Int
    @Property(title: "User") var username: String
    @Property(title: "Tags") var tags: [String]
    @Property(title: "Favorite") var isFavorite: Bool
    @Property(title: "Last Connected") var lastConnected: Date?
    @Property(title: "Jump Hosts") var jumpHosts: [String]

    @MainActor init(_ host: Host) {
        id = host.id
        name = host.displayName
        address = host.address
        hostname = host.hostname
        port = host.port
        username = host.username
        tags = host.tags
        isFavorite = host.isFavorite
        lastConnected = host.lastConnected
        jumpHosts = host.jumpHostIDs.compactMap { AppModel.shared.host($0)?.displayName }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(address)", image: .init(systemName: isFavorite ? "star.fill" : "server.rack")
        )
    }
}

struct HostQuery: EntityPropertyQuery, EntityStringQuery {
    typealias ComparatorMappingType = (HostEntity) -> Bool

    // immutable but not marked sendable by the sdk, and the metadata extractor
    // only accepts a stored initialiser here (same in the queries below)
    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\HostEntity.$name) {
            ContainsComparator { value in
                { (entity: HostEntity) in entity.name.localizedCaseInsensitiveContains(value) }
            }
            EqualToComparator { value in
                { (entity: HostEntity) in entity.name.equalsIgnoringCase(value) }
            }
        }
        Property(\HostEntity.$hostname) {
            ContainsComparator { value in
                { (entity: HostEntity) in entity.hostname.localizedCaseInsensitiveContains(value) }
            }
            EqualToComparator { value in
                { (entity: HostEntity) in entity.hostname.equalsIgnoringCase(value) }
            }
        }
        Property(\HostEntity.$username) {
            EqualToComparator { value in { (entity: HostEntity) in entity.username == value } }
        }
        Property(\HostEntity.$port) {
            EqualToComparator { value in { (entity: HostEntity) in entity.port == value } }
        }
        Property(\HostEntity.$tags) {
            ContainsComparator { value in
                { (entity: HostEntity) in
                    entity.tags.contains { $0.equalsIgnoringCase(value) }
                }
            }
        }
        Property(\HostEntity.$isFavorite) {
            EqualToComparator { value in { (entity: HostEntity) in entity.isFavorite == value } }
        }
        Property(\HostEntity.$lastConnected) {
            GreaterThanComparator { value in { (entity: HostEntity) in (entity.lastConnected ?? .distantPast) > value }
            }
            LessThanComparator { value in { (entity: HostEntity) in (entity.lastConnected ?? .distantPast) < value } }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\HostEntity.$name)
        SortableBy(\HostEntity.$lastConnected)
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        AppModel.shared.hosts.filter { identifiers.contains($0.id) }.map(HostEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [HostEntity] {
        AppModel.shared.hosts.map(HostEntity.init).filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.address.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor func suggestedEntities() async throws -> [HostEntity] {
        AppModel.shared.hosts.map(HostEntity.init)
    }

    func entities(
        matching comparators: [ComparatorMappingType], mode: ComparatorMode, sortedBy: [Sort<HostEntity>], limit: Int?
    ) async throws -> [HostEntity] {
        await MainActor.run { AppModel.shared.hosts.map(HostEntity.init) }.query(
            comparators, mode: mode, sortedBy: sortedBy, limit: limit,
            orders: [
                \HostEntity.$name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                \HostEntity.$lastConnected: { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) },
            ])
    }
}

enum TunnelKindEnum: String, AppEnum {
    case local, remote, dynamic

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel Kind"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .local: DisplayRepresentation(title: "Local (-L)", subtitle: "A port on this device reaches the remote side"),
        .remote: DisplayRepresentation(title: "Remote (-R)", subtitle: "A port on the server reaches this side"),
        .dynamic: DisplayRepresentation(title: "Dynamic (-D)", subtitle: "A SOCKS5 proxy on this device"),
    ]

    init(_ kind: Tunnel.Kind) {
        self =
            switch kind {
            case .local: .local
            case .remote: .remote
            case .dynamic: .dynamic
            }
    }
}

struct TunnelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tunnel", numericFormat: "\(placeholder: .int) tunnels")
    static let defaultQuery = TunnelQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: TunnelKindEnum
    @Property(title: "Bind Port") var bindPort: Int
    @Property(title: "Target") var target: String
    @Property(title: "Host") var hostName: String
    @Property(title: "Running") var isRunning: Bool
    /// differs from the bind port when that was 0
    @Property(title: "Listening Port") var listeningPort: Int?
    @Property(title: "Error") var error: String?

    @MainActor init(_ tunnel: Tunnel) {
        id = tunnel.id
        name = tunnel.displayName
        kind = TunnelKindEnum(tunnel.kind)
        bindPort = tunnel.bindPort
        target = tunnel.kind == .dynamic ? "" : "\(tunnel.targetHost):\(tunnel.targetPort)"
        hostName = AppModel.shared.host(tunnel.hostID)?.displayName ?? ""
        switch AppModel.shared.tunnels.status[tunnel.id] {
        case .running(let port):
            isRunning = true
            listeningPort = port
        case .failed(let message):
            isRunning = false
            error = message
        case .starting, nil:
            isRunning = false
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(hostName)",
            image: .init(
                systemName: isRunning
                    ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"))
    }
}

struct TunnelQuery: EntityPropertyQuery, EntityStringQuery {
    typealias ComparatorMappingType = (TunnelEntity) -> Bool

    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\TunnelEntity.$name) {
            ContainsComparator { value in
                { (entity: TunnelEntity) in entity.name.localizedCaseInsensitiveContains(value) }
            }
        }
        Property(\TunnelEntity.$kind) {
            EqualToComparator { value in { (entity: TunnelEntity) in entity.kind == value } }
        }
        Property(\TunnelEntity.$hostName) {
            EqualToComparator { value in
                { (entity: TunnelEntity) in entity.hostName.equalsIgnoringCase(value) }
            }
            ContainsComparator { value in
                { (entity: TunnelEntity) in entity.hostName.localizedCaseInsensitiveContains(value) }
            }
        }
        Property(\TunnelEntity.$isRunning) {
            EqualToComparator { value in { (entity: TunnelEntity) in entity.isRunning == value } }
        }
        Property(\TunnelEntity.$bindPort) {
            EqualToComparator { value in { (entity: TunnelEntity) in entity.bindPort == value } }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\TunnelEntity.$name)
        SortableBy(\TunnelEntity.$bindPort)
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [TunnelEntity] {
        AppModel.shared.savedTunnels.filter { identifiers.contains($0.id) }.map(TunnelEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [TunnelEntity] {
        AppModel.shared.savedTunnels.map(TunnelEntity.init).filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.hostName.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor func suggestedEntities() async throws -> [TunnelEntity] {
        AppModel.shared.savedTunnels.map(TunnelEntity.init)
    }

    func entities(
        matching comparators: [ComparatorMappingType], mode: ComparatorMode, sortedBy: [Sort<TunnelEntity>],
        limit: Int?
    ) async throws -> [TunnelEntity] {
        await MainActor.run { AppModel.shared.savedTunnels.map(TunnelEntity.init) }.query(
            comparators, mode: mode, sortedBy: sortedBy, limit: limit,
            orders: [
                \TunnelEntity.$name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                \TunnelEntity.$bindPort: { $0.bindPort < $1.bindPort },
            ])
    }
}

struct SnippetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Snippet", numericFormat: "\(placeholder: .int) snippets")
    static let defaultQuery = SnippetQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Command") var command: String
    @Property(title: "Placeholders") var placeholders: [String]

    init(_ snippet: Snippet) {
        id = snippet.id
        name = snippet.name
        command = snippet.command
        placeholders = snippet.placeholders
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(command)", image: .init(systemName: "text.alignleft"))
    }
}

struct SnippetQuery: EntityPropertyQuery, EntityStringQuery {
    typealias ComparatorMappingType = (SnippetEntity) -> Bool

    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\SnippetEntity.$name) {
            ContainsComparator { value in
                { (entity: SnippetEntity) in entity.name.localizedCaseInsensitiveContains(value) }
            }
            EqualToComparator { value in
                { (entity: SnippetEntity) in entity.name.equalsIgnoringCase(value) }
            }
        }
        Property(\SnippetEntity.$command) {
            ContainsComparator { value in
                { (entity: SnippetEntity) in entity.command.localizedCaseInsensitiveContains(value) }
            }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\SnippetEntity.$name)
    }

    @MainActor func entities(for identifiers: [UUID]) async throws -> [SnippetEntity] {
        AppModel.shared.snippets.filter { identifiers.contains($0.id) }.map(SnippetEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [SnippetEntity] {
        AppModel.shared.snippets.map(SnippetEntity.init).filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.command.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor func suggestedEntities() async throws -> [SnippetEntity] {
        AppModel.shared.snippets.map(SnippetEntity.init)
    }

    func entities(
        matching comparators: [ComparatorMappingType], mode: ComparatorMode, sortedBy: [Sort<SnippetEntity>],
        limit: Int?
    ) async throws -> [SnippetEntity] {
        await MainActor.run { AppModel.shared.snippets.map(SnippetEntity.init) }.query(
            comparators, mode: mode, sortedBy: sortedBy, limit: limit,
            orders: [\SnippetEntity.$name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }])
    }
}

enum KeyKindEnum: String, AppEnum {
    case ed25519, ecdsaP256, ecdsaP384, ecdsaP521, rsa, secureEnclaveP256

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Key Type"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .ed25519: "Ed25519",
        .ecdsaP256: "ECDSA P-256",
        .ecdsaP384: "ECDSA P-384",
        .ecdsaP521: "ECDSA P-521",
        .rsa: "RSA",
        .secureEnclaveP256: "Secure Enclave P-256",
    ]

    init(_ kind: KeyKind) { self = Self(rawValue: kind.rawValue) ?? .ed25519 }
}

struct IdentityEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "SSH Key", numericFormat: "\(placeholder: .int) SSH keys")
    static let defaultQuery = IdentityQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Type") var kind: KeyKindEnum
    @Property(title: "Public Key") var publicKey: String
    @Property(title: "Fingerprint") var fingerprint: String
    @Property(title: "Requires Face ID") var requiresBiometry: Bool

    init(_ identity: Identity) {
        id = identity.id
        name = identity.name
        kind = KeyKindEnum(identity.kind)
        publicKey = identity.publicKey
        fingerprint = (try? SSHPublicKey(authorizedKeysLine: identity.publicKey).fingerprint) ?? ""
        requiresBiometry = identity.requiresBiometry
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(fingerprint)", image: .init(systemName: "key.fill"))
    }
}

struct IdentityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [IdentityEntity] {
        AppModel.shared.identities.filter { identifiers.contains($0.id) }.map(IdentityEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [IdentityEntity] {
        AppModel.shared.identities.filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(IdentityEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [IdentityEntity] {
        AppModel.shared.identities.map(IdentityEntity.init)
    }
}

struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Open Session", numericFormat: "\(placeholder: .int) open sessions")
    static let defaultQuery = SessionQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Host") var host: HostEntity
    @Property(title: "Connected") var isConnected: Bool

    @MainActor init(_ session: Session) {
        id = session.id
        title = session.displayTitle
        host = HostEntity(session.host)
        isConnected = session.state == .connected
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: "\(host.address)",
            image: .init(systemName: isConnected ? "terminal.fill" : "terminal"))
    }
}

struct SessionQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SessionEntity] {
        AppModel.shared.sessions.sessions.filter { identifiers.contains($0.id) }.map(SessionEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [SessionEntity] {
        AppModel.shared.sessions.sessions.map(SessionEntity.init)
    }
}

struct CommandResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Command Result", numericFormat: "\(placeholder: .int) command results")

    @Property(title: "Host") var host: String
    @Property(title: "Output") var output: String
    @Property(title: "Error Output") var errorOutput: String
    /// missing when the command never finished, or the server didn't say
    @Property(title: "Exit Status") var exitStatus: Int?
    @Property(title: "Succeeded") var succeeded: Bool
    /// why it couldn't run at all, like an unreachable host
    @Property(title: "Failure") var failure: String?
    @Property(title: "Duration (Seconds)") var duration: Double

    init() {
        host = ""
        output = ""
        errorOutput = ""
        succeeded = false
        duration = 0
    }

    var displayRepresentation: DisplayRepresentation {
        let status = failure ?? exitStatus.map { "exit \($0)" } ?? "no exit status"
        return DisplayRepresentation(
            title: "\(host)", subtitle: "\(status)",
            image: .init(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
    }
}

extension Array {
    /// filters and sorts for an `EntityPropertyQuery`; sorts on properties
    /// missing from `orders` are ignored
    func query(
        _ comparators: [(Element) -> Bool], mode: EntityQueryComparatorMode,
        sortedBy sorts: [EntityQuerySort<Element>], limit: Int?,
        orders: [PartialKeyPath<Element>: (Element, Element) -> Bool]
    ) -> [Element] where Element: AppEntity {
        var items = filter { item in
            switch mode {
            case .and: comparators.allSatisfy { $0(item) }
            case .or: comparators.isEmpty || comparators.contains { $0(item) }
            @unknown default: comparators.allSatisfy { $0(item) }
            }
        }
        if !sorts.isEmpty {
            items.sort { a, b in
                for sort in sorts {
                    guard let less = orders[sort.by] else { continue }
                    if less(a, b) { return sort.order == .ascending }
                    if less(b, a) { return sort.order == .descending }
                }
                return false
            }
        }
        return limit.map { Array(items.prefix($0)) } ?? items
    }
}
