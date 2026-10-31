import Foundation
import os

/// everything non-secret, in one json file.
public struct AppData: Codable, Sendable, Equatable {
    public var hosts: [Host] = []
    public var identities: [Identity] = []
    public var tunnels: [Tunnel] = []
    public var snippets: [Snippet] = []
    public var knownHosts: [KnownHost] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        identities = try c.decodeIfPresent([Identity].self, forKey: .identities) ?? []
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        knownHosts = try c.decodeIfPresent([KnownHost].self, forKey: .knownHosts) ?? []
    }

    public enum HostKeyStatus: Equatable, Sendable {
        case trusted
        case unknown
        case changed(previous: KnownHost)
    }

    public func status(of key: SSHPublicKey, host: String, port: Int) -> HostKeyStatus {
        // a host may have several key types on file; any exact match is trusted.
        let entries = knownHosts.filter { $0.host == host && $0.port == port }
        if entries.contains(where: { $0.key == key.blob }) { return .trusted }
        // any other key on file is a mismatch, reported against the same-algorithm
        // key when there is one.
        if let previous = entries.first(where: { $0.algorithm == key.algorithm }) ?? entries.first {
            return .changed(previous: previous)
        }
        return .unknown
    }

    /// replaces any earlier keys for that host.
    public mutating func trust(_ key: SSHPublicKey, host: String, port: Int) {
        knownHosts.removeAll { $0.host == host && $0.port == port }
        knownHosts.append(KnownHost(host: host, port: port, algorithm: key.algorithm, key: key.blob))
    }
}

public struct Store: Sendable {
    public let url: URL
    private static let log = Logger(subsystem: "catgirl.engineering.pounce", category: "store")

    public init(url: URL? = nil) {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.url = url ?? base.appendingPathComponent("pounce.json")
    }

    public func load() -> AppData {
        guard let data = try? Data(contentsOf: url) else { return AppData() }
        do {
            return try JSONDecoder().decode(AppData.self, from: data)
        } catch {
            Self.log.error("couldn't read saved data: \(error.localizedDescription, privacy: .public)")
            // keep the unreadable file rather than overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return AppData()
        }
    }

    public func save(_ data: AppData) {
        do {
            try JSONEncoder().encode(data).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("couldn't save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
