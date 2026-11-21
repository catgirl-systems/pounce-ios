import Foundation

public struct Host: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var identityID: UUID?
    public var jumpHostIDs: [UUID]
    public var tags: [String]
    public var isFavorite: Bool
    public var lastConnected: Date?
    public var startupSnippetID: UUID?
    public var themeID: String?
    public var icon: String?
    public var syncsPassword: Bool

    public init(
        id: UUID = UUID(), label: String = "", hostname: String, port: Int = 22, username: String,
        identityID: UUID? = nil, jumpHostIDs: [UUID] = [], tags: [String] = [], isFavorite: Bool = false,
        lastConnected: Date? = nil, startupSnippetID: UUID? = nil, themeID: String? = nil, icon: String? = nil,
        syncsPassword: Bool = false
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityID = identityID
        self.jumpHostIDs = jumpHostIDs
        self.tags = tags
        self.isFavorite = isFavorite
        self.lastConnected = lastConnected
        self.startupSnippetID = startupSnippetID
        self.themeID = themeID
        self.icon = icon
        self.syncsPassword = syncsPassword
    }

    public var displayName: String { label.isEmpty ? address : label }

    public var address: String { endpoint.description }

    public var endpoint: SSHEndpoint { SSHEndpoint(host: hostname, port: port, username: username) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        identityID = try c.decodeIfPresent(UUID.self, forKey: .identityID)
        jumpHostIDs = try c.decodeIfPresent([UUID].self, forKey: .jumpHostIDs) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        startupSnippetID = try c.decodeIfPresent(UUID.self, forKey: .startupSnippetID)
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        syncsPassword = try c.decodeIfPresent(Bool.self, forKey: .syncsPassword) ?? false
    }
}

/// public half only, the private key is in the keychain or secure enclave
public struct Identity: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: KeyKind
    /// an `authorized_keys` line
    public var publicKey: String
    public var created: Date
    public var requiresBiometry: Bool
    public var icon: String?
    public var syncsKey: Bool
    /// set when a device that held the synced private key was removed
    public var exposedAt: Date?

    public init(
        id: UUID = UUID(), name: String, kind: KeyKind, publicKey: String, created: Date = .now,
        requiresBiometry: Bool = false, icon: String? = nil, syncsKey: Bool = false, exposedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.created = created
        self.requiresBiometry = requiresBiometry
        self.icon = icon
        self.syncsKey = syncsKey
        self.exposedAt = exposedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(KeyKind.self, forKey: .kind)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        created = try c.decode(Date.self, forKey: .created)
        requiresBiometry = try c.decodeIfPresent(Bool.self, forKey: .requiresBiometry) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        syncsKey = try c.decodeIfPresent(Bool.self, forKey: .syncsKey) ?? false
        exposedAt = try c.decodeIfPresent(Date.self, forKey: .exposedAt)
    }
}

public struct Tunnel: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case local
        case remote
        case dynamic
    }

    public var id: UUID
    public var name: String
    public var hostID: UUID
    public var kind: Kind
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(
        id: UUID = UUID(), name: String = "", hostID: UUID, kind: Kind, bindPort: Int, targetHost: String = "",
        targetPort: Int = 0
    ) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.kind = kind
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public var summary: String {
        switch kind {
        case .local: "-L \(bindPort):\(targetHost):\(targetPort)"
        case .remote: "-R \(bindPort):\(targetHost):\(targetPort)"
        case .dynamic: "-D \(bindPort)"
        }
    }

    public var displayName: String { name.isEmpty ? summary : name }
}

/// `{{name}}` placeholders are asked for when it runs
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var runImmediately: Bool

    public init(id: UUID = UUID(), name: String, command: String, runImmediately: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.runImmediately = runImmediately
    }

    public var placeholders: [String] {
        var seen: [String] = []
        var rest = command[...]
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
            rest = rest[close.upperBound...]
        }
        return seen
    }

    public func filled(_ values: [String: String]) -> String {
        var result = command
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
            result = result.replacingOccurrences(of: "{{ \(name) }}", with: value)
        }
        return result
    }
}

public struct KnownHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var host: String
    public var port: Int
    public var algorithm: String
    public var key: Data
    public var added: Date

    public init(id: UUID = UUID(), host: String, port: Int, algorithm: String, key: Data, added: Date = .now) {
        self.id = id
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.key = key
        self.added = added
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        algorithm = try c.decode(String.self, forKey: .algorithm)
        key = try c.decode(Data.self, forKey: .key)
        added = try c.decode(Date.self, forKey: .added)
    }
}

extension Array where Element: Identifiable {
    /// setting replaces or appends the element; setting nil removes it
    public subscript(id id: Element.ID?) -> Element? {
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
