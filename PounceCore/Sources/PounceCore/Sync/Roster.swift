import Foundation

/// a device in the sync account. `meta` is plaintext json the server can read,
/// so it only ever holds a short device name.
public struct RosterDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: Data
    public var signPub: Data
    public var kemPub: Data
    public var meta: Data
    public var active: Bool

    public var name: String {
        (try? JSONDecoder().decode(DeviceMeta.self, from: meta))?.name ?? "Device"
    }
}

struct DeviceMeta: Codable {
    var name: String

    static func encode(_ name: String) -> Data {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return (try? JSONEncoder().encode(DeviceMeta(name: trimmed.isEmpty ? "Device" : trimmed))) ?? Data()
    }
}

/// the verified roster: the same rules as pounce-sync's `roster.Apply`, checked
/// again here so a dishonest server can't add a device or skip a rotation.
public struct RosterState: Codable, Equatable, Sendable {
    public var accountID: Data
    public var count: UInt64 = 0
    public var headHash = Data(count: 32)
    public var epoch: UInt32 = 0
    public var rotatePending = false
    public var recoveryID = Data()
    public var recoverySignPub = Data()
    public var recoveryKemPub = Data()
    public var devices: [RosterDevice] = []

    static let maxActive = 32
    static let maxEntries: UInt64 = 10_000
    static let label = "pounce/v1/roster"

    init(accountID: Data) { self.accountID = accountID }

    public var activeDevices: [RosterDevice] { devices.filter(\.active) }

    func device(_ id: Data) -> RosterDevice? { devices.first { $0.id == id } }

    func active(_ id: Data) -> RosterDevice? { devices.first { $0.id == id && $0.active } }

    private func used(_ id: Data) -> Bool { device(id) != nil || id == recoveryID }

    enum Action: String {
        case genesis
        case addDevice = "add_device"
        case removeDevice = "remove_device"
        case rotate
        case recover
    }

    struct NewDevice {
        var id: Data
        var signPub: Data
        var kemPub: Data
        var meta: Data
    }

    struct Entry {
        var action: Action
        var device: NewDevice?
        var target: Data?
        var epoch: UInt32?
        var signerID: Data
        var recovery: (id: Data, signPub: Data, kemPub: Data)?
    }

    // MARK: building

    /// the body of the next entry; `apply` it with its signature to advance.
    func body(_ entry: Entry) -> Data {
        var fields: [WireField] = [
            .text(Self.label), .bytes(accountID), .u64(count), .bytes(count == 0 ? Data(count: 32) : headHash),
            .text(entry.action.rawValue),
        ]
        if let device = entry.device {
            fields += [.bytes(device.id), .bytes(device.signPub), .bytes(device.kemPub), .bytes(device.meta)]
        }
        if let recovery = entry.recovery {
            fields += [.bytes(recovery.id), .bytes(recovery.signPub), .bytes(recovery.kemPub)]
        }
        if let target = entry.target { fields.append(.bytes(target)) }
        if let epoch = entry.epoch { fields.append(.u32(epoch)) }
        fields.append(.bytes(entry.signerID))
        return SyncCrypto.message(fields)
    }

    // MARK: verifying

    private static func parse(_ body: Data) throws(SyncError) -> (account: Data, index: UInt64, prev: Data, Entry) {
        var reader = SSHReader([UInt8](body))
        do {
            func bytes() throws(KeyError) -> Data { Data(try reader.readString()) }
            guard try reader.readText() == label else { throw SyncError.rosterInvalid }
            let account = try bytes()
            let index = try reader.readUInt64()
            let prev = try bytes()
            guard let action = Action(rawValue: try reader.readText()) else { throw SyncError.rosterInvalid }
            var entry = Entry(action: action, signerID: Data())
            switch action {
            case .genesis, .addDevice, .recover:
                entry.device = NewDevice(id: try bytes(), signPub: try bytes(), kemPub: try bytes(), meta: try bytes())
                if action == .genesis { entry.recovery = (try bytes(), try bytes(), try bytes()) }
            case .removeDevice: entry.target = try bytes()
            case .rotate: entry.epoch = try reader.readUInt32()
            }
            entry.signerID = try bytes()
            guard reader.isAtEnd, account.count == 16, prev.count == 32, entry.signerID.count == 16 else {
                throw SyncError.rosterInvalid
            }
            if let device = entry.device {
                guard device.id.count == 16, SyncCrypto.signingKey(device.signPub) != nil,
                    SyncCrypto.agreementKey(device.kemPub) != nil, device.meta.count <= 1024
                else { throw SyncError.rosterInvalid }
            }
            if let recovery = entry.recovery {
                guard recovery.id.count == 16, SyncCrypto.signingKey(recovery.signPub) != nil,
                    SyncCrypto.agreementKey(recovery.kemPub) != nil
                else { throw SyncError.rosterInvalid }
            }
            if let target = entry.target, target.count != 16 { throw SyncError.rosterInvalid }
            return (account, index, prev, entry)
        } catch {
            throw .rosterInvalid
        }
    }

    /// checks every rule for appending `(body, sig)` next; on error nothing changes.
    @discardableResult
    mutating func apply(_ body: Data, _ sig: Data) throws(SyncError) -> Entry {
        let (account, index, prev, entry) = try Self.parse(body)
        guard account == accountID, index == count, !(index >= Self.maxEntries && entry.action == .addDevice),
            prev == (count == 0 ? Data(count: 32) : headHash), (count == 0) == (entry.action == .genesis)
        else { throw .rosterInvalid }

        var signer = active(entry.signerID)?.signPub
        let allowed: Bool
        switch entry.action {
        case .genesis:
            signer = entry.device?.signPub
            allowed = entry.signerID == entry.device?.id && entry.device?.id != entry.recovery?.id
        case .addDevice:
            allowed = signer != nil && !used(entry.device?.id ?? Data()) && activeDevices.count < Self.maxActive
        case .removeDevice:
            allowed = signer != nil && active(entry.target ?? Data()) != nil
        case .rotate:
            allowed = signer != nil && rotatePending && entry.epoch == epoch + 1
        case .recover:
            signer = recoverySignPub
            allowed = entry.signerID == recoveryID && !used(entry.device?.id ?? Data())
        }
        guard allowed, let signer, SyncCrypto.verify(sig, for: body, publicKey: signer) else {
            throw .rosterInvalid
        }

        switch entry.action {
        case .genesis:
            epoch = 1
            if let recovery = entry.recovery {
                (recoveryID, recoverySignPub, recoveryKemPub) = recovery
            }
        case .removeDevice:
            if let i = devices.firstIndex(where: { $0.id == entry.target }) { devices[i].active = false }
            rotatePending = true
        case .rotate:
            epoch = entry.epoch ?? epoch
            rotatePending = false
        case .recover:
            for i in devices.indices { devices[i].active = false }
            rotatePending = true
        case .addDevice: break
        }
        if let device = entry.device {
            devices.append(
                RosterDevice(
                    id: device.id, signPub: device.signPub, kemPub: device.kemPub, meta: device.meta, active: true))
        }
        count += 1
        headHash = SyncCrypto.sha256(SyncCrypto.message(.bytes(body), .bytes(sig)))
        return entry
    }
}
