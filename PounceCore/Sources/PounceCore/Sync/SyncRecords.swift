import Foundation

/// the decrypted content of one record. items keep their own uuid as the record
/// id; a synced private key or password gets an id derived from its owner's.
struct SyncPayload: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case host
        case identity
        case tunnel
        case snippet
        case knownHost
        case key
        case password
    }

    var kind: Kind
    /// milliseconds; the later edit wins a conflict.
    var modified: Int64
    var deleted: Bool?
    var host: Host?
    var identity: Identity?
    var tunnel: Tunnel?
    var snippet: Snippet?
    var knownHost: KnownHost?
    var owner: UUID?
    var key: PrivateKeyMaterial?
    var password: String?

    var isDeleted: Bool { deleted == true }

    static func tombstone(_ kind: Kind, modified: Int64, owner: UUID? = nil) -> SyncPayload {
        SyncPayload(kind: kind, modified: modified, deleted: true, owner: owner)
    }

    var isSecret: Bool { kind == .key || kind == .password }

    func encoded() throws(SyncError) -> Data {
        do { return try SyncRecords.encoder.encode(self) } catch { throw .malformed }
    }
}

enum SyncRecords {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func secretID(_ kind: SyncPayload.Kind, owner: UUID) -> Data {
        SyncCrypto.sha256(SyncCrypto.message(.text("pounce/v1/secret-id"), .text(kind.rawValue), .bytes(owner.data)))
            .prefix(16)
    }

    struct Item {
        var id: Data
        var payload: SyncPayload
        var hash: Data
    }

    /// every non-secret item as it would be uploaded, with a content hash that
    /// ignores device-local fields (recents) and the edit time.
    static func items(_ data: AppData) -> [Data: Item] {
        var out: [Data: Item] = [:]
        func add(_ id: UUID, _ payload: SyncPayload) {
            let hash = (try? encoder.encode(payload)).map(SyncCrypto.sha256) ?? Data()
            out[id.data] = Item(id: id.data, payload: payload, hash: hash)
        }
        for var host in data.hosts {
            host.lastConnected = nil
            add(host.id, SyncPayload(kind: .host, modified: 0, host: host))
        }
        for identity in data.identities {
            add(identity.id, SyncPayload(kind: .identity, modified: 0, identity: identity))
        }
        for tunnel in data.tunnels { add(tunnel.id, SyncPayload(kind: .tunnel, modified: 0, tunnel: tunnel)) }
        for snippet in data.snippets { add(snippet.id, SyncPayload(kind: .snippet, modified: 0, snippet: snippet)) }
        for known in data.knownHosts { add(known.id, SyncPayload(kind: .knownHost, modified: 0, knownHost: known)) }
        return out
    }

    static func hash(_ payload: SyncPayload) -> Data {
        var bare = payload
        bare.modified = 0
        bare.host?.lastConnected = nil
        return (try? encoder.encode(bare)).map(SyncCrypto.sha256) ?? Data()
    }

    struct Change: Sendable {
        var id: Data
        var payload: SyncPayload
        /// the local item's hash when the change was decided; nil if it didn't exist.
        var expected: Data?
    }

    /// applies remote changes to `data`, skipping any item edited locally since
    /// `expected` was taken (the next round settles it). returns the skipped ids.
    static func apply(_ changes: [Change], to data: inout AppData) -> Set<Data> {
        let current = items(data)
        var skipped: Set<Data> = []
        for change in changes {
            guard current[change.id]?.hash == change.expected else {
                skipped.insert(change.id)
                continue
            }
            apply(change.payload, id: change.id, to: &data)
        }
        return skipped
    }

    private static func apply(_ payload: SyncPayload, id: Data, to data: inout AppData) {
        guard let uuid = UUID(data: id) else { return }
        let deleted = payload.isDeleted
        switch payload.kind {
        case .host:
            let recent = data.hosts[id: uuid]?.lastConnected
            data.hosts[id: uuid] =
                deleted
                ? nil
                : payload.host.map {
                    var host = $0
                    host.id = uuid
                    host.lastConnected = recent
                    return host
                }
        case .identity:
            data.identities[id: uuid] = deleted ? nil : payload.identity.map { with($0) { $0.id = uuid } }
        case .tunnel:
            data.tunnels[id: uuid] = deleted ? nil : payload.tunnel.map { with($0) { $0.id = uuid } }
        case .snippet:
            data.snippets[id: uuid] = deleted ? nil : payload.snippet.map { with($0) { $0.id = uuid } }
        case .knownHost:
            data.knownHosts[id: uuid] = deleted ? nil : payload.knownHost.map { with($0) { $0.id = uuid } }
            dedupeKnownHosts(&data)
        case .key, .password:
            break
        }
    }

    /// two devices trusting a host at once leave two entries; every device keeps
    /// the same one (latest, then highest id), and deleting the other syncs too.
    private static func dedupeKnownHosts(_ data: inout AppData) {
        var keep: [String: KnownHost] = [:]
        for known in data.knownHosts {
            let slot = "\(known.host):\(known.port)"
            if let other = keep[slot],
                (other.added, other.id.uuidString) > (known.added, known.id.uuidString)
            {
                continue
            }
            keep[slot] = known
        }
        data.knownHosts.removeAll { keep["\($0.host):\($0.port)"]?.id != $0.id }
    }

    private static func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
        var value = value
        change(&value)
        return value
    }
}

extension Array where Element: Identifiable {
    fileprivate subscript(id id: Element.ID) -> Element? {
        get { first { $0.id == id } }
        set {
            guard let newValue else { return removeAll { $0.id == id } }
            if let index = firstIndex(where: { $0.id == id }) {
                self[index] = newValue
            } else {
                append(newValue)
            }
        }
    }
}
