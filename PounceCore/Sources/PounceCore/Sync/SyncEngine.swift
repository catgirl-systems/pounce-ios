import CryptoKit
import Foundation
import os

/// everything the engine remembers between launches, none of it secret: the
/// verified roster, the feed position and what the server holds for each record.
public struct SyncState: Codable, Sendable {
    public var origin: URL
    public var accountID: Data
    public var deviceID: Data
    public var roster: RosterState
    var since: UInt64 = 0
    var marks: [String: Mark] = [:]
    /// when each item still waiting to upload was first seen edited, by hex id.
    var edits: [String: Int64] = [:]

    struct Mark: Codable, Sendable {
        var id: Data
        var rev: UInt64
        var kind: SyncPayload.Kind
        /// content hash; empty for a deletion.
        var hash: Data
        var deleted: Bool
        var owner: UUID?
    }
}

public struct SyncReport: Sendable, Equatable {
    public var received = 0
    public var sent = 0
    /// records that failed to decrypt or verify: a sign of a tampering server.
    public var rejected = 0

    public init() {}

    static func + (a: SyncReport, b: SyncReport) -> SyncReport {
        var sum = a
        sum.received += b.received
        sum.sent += b.sent
        sum.rejected += b.rejected
        return sum
    }
}

/// how the engine reads and changes the app's data, on whatever actor owns it.
/// a nil snapshot means sync was turned off meanwhile: the engine stops rather
/// than upload whatever the app holds now (after an erase, nothing).
public struct SyncHooks: Sendable {
    public var snapshot: @Sendable () async -> AppData?
    /// runs `body` on the live data and returns its result.
    public var mutate: @Sendable (_ body: @escaping @Sendable (inout AppData) -> Set<Data>) async -> Set<Data>

    public init(
        snapshot: @escaping @Sendable () async -> AppData?,
        mutate: @escaping @Sendable (_ body: @escaping @Sendable (inout AppData) -> Set<Data>) async -> Set<Data>
    ) {
        self.snapshot = snapshot
        self.mutate = mutate
    }
}

public struct PairingInvite: Sendable {
    /// for the qr code: `pounce-pair:` and the invite, base64url.
    public let code: String
    let id: Data
}

public struct PairingRequest: Sendable {
    /// six digits, to compare with what the joining device shows.
    public let code: String
    public let deviceName: String
    let device: RosterState.NewDevice
}

public actor SyncEngine {
    public private(set) var state: SyncState
    let api: SyncAPI
    let vault: any SyncVault
    let stateURL: URL
    let hooks: SyncHooks
    private var token: String?
    private var epochKeys: [UInt32: SymmetricKey]
    private var running = false
    private var rerun = false
    private static let log = Logger(subsystem: "catgirl.engineering.pounce", category: "sync")

    init(state: SyncState, vault: any SyncVault, stateURL: URL, hooks: SyncHooks) throws(SyncError) {
        self.state = state
        self.api = try SyncAPI(origin: state.origin)
        self.vault = vault
        self.stateURL = stateURL
        self.hooks = hooks
        self.epochKeys = vault.epochKeys().mapValues { SymmetricKey(data: $0) }
    }

    public static func load(stateURL: URL, vault: any SyncVault, hooks: SyncHooks) -> SyncEngine? {
        guard let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(SyncState.self, from: data),
            (try? vault.deviceKeys()) != nil
        else { return nil }
        return try? SyncEngine(state: state, vault: vault, stateURL: stateURL, hooks: hooks)
    }

    public var deviceID: Data { state.deviceID }
    public var devices: [RosterDevice] { state.roster.activeDevices }
    public var origin: String { api.originText }

    private func save() {
        do {
            try JSONEncoder().encode(state).write(
                to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("couldn't save sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deviceKeys() throws(SyncError) -> DeviceKeys {
        guard let keys = try vault.deviceKeys() else { throw .notSetUp }
        return keys
    }

    private func remember(_ key: SymmetricKey, epoch: UInt32) throws(SyncError) {
        epochKeys[epoch] = key
        try vault.saveEpochKeys(epochKeys.mapValues { $0.withUnsafeBytes { Data($0) } })
    }

    // MARK: sessions

    private func session() async throws(SyncError) -> String {
        if let token { return token }
        let signer = try deviceKeys().signer()
        let nonce: Data
        do {
            nonce = try await api.challenge(account: state.accountID, device: state.deviceID)
        } catch .server(status: 401, _) {
            throw .removed
        }
        let sig = try SyncCrypto.sign(
            Self.authMessage(origin: api.originText, account: state.accountID, device: state.deviceID, nonce: nonce),
            with: signer)
        let token = try await api.login(account: state.accountID, device: state.deviceID, nonce: nonce, sig: sig)
        self.token = token
        return token
    }

    /// runs `body` with a session, logging in again once when the token expired.
    private func withSession<T: Sendable>(_ body: (String) async throws(SyncError) -> T) async throws(SyncError) -> T {
        do {
            return try await body(try await session())
        } catch .server(status: 401, _) {
            token = nil
            return try await body(try await session())
        }
    }

    static func authMessage(origin: String, account: Data, device: Data, nonce: Data) -> Data {
        SyncCrypto.message(.text("pounce/v1/auth"), .text(origin), .bytes(account), .bytes(device), .bytes(nonce))
    }

    static func wrappedKeyMessage(account: Data, recipient: Data, epoch: UInt32, blob: Data) -> Data {
        SyncCrypto.message(
            .text("pounce/v1/wrapped-key"), .bytes(account), .bytes(recipient), .u32(epoch), .bytes(blob))
    }

    static func wrap(
        _ key: SymmetricKey, epoch: UInt32, account: Data, to recipient: (id: Data, kemPub: Data),
        signer: P256.Signing.PrivateKey, signerID: Data
    ) throws(SyncError) -> WireKey {
        let blob = try SyncCrypto.wrap(
            key, to: recipient.kemPub, account: account, recipient: recipient.id, epoch: epoch)
        let sig = try SyncCrypto.sign(
            wrappedKeyMessage(account: account, recipient: recipient.id, epoch: epoch, blob: blob), with: signer)
        return WireKey(
            recipientID: B64(recipient.id), epoch: epoch, blob: B64(blob), signerID: B64(signerID), sig: B64(sig))
    }

    /// a wrapped key counts only when a device of the verified roster signed it.
    static func unwrap(
        _ wire: WireKey, roster: RosterState, recipient: Data, epoch: UInt32, with key: P256.KeyAgreement.PrivateKey
    ) throws(SyncError) -> SymmetricKey {
        guard wire.epoch == epoch, wire.recipientID.data == recipient,
            let signer = roster.device(wire.signerID.data),
            SyncCrypto.verify(
                wire.sig.data,
                for: wrappedKeyMessage(
                    account: roster.accountID, recipient: recipient, epoch: epoch, blob: wire.blob.data),
                publicKey: signer.signPub)
        else { throw .rosterInvalid }
        return try SyncCrypto.unwrap(
            wire.blob.data, with: key, account: roster.accountID, recipient: recipient, epoch: epoch)
    }

    private func epochKey(_ epoch: UInt32, token: String) async throws(SyncError) -> SymmetricKey {
        if let key = epochKeys[epoch] { return key }
        guard let wire = try await api.key(token: token, epoch: epoch) else { throw .missingKey(epoch: epoch) }
        let key = try Self.unwrap(
            wire, roster: state.roster, recipient: state.deviceID, epoch: epoch, with: try deviceKeys().agreer())
        try remember(key, epoch: epoch)
        return key
    }

    /// fetches the roster from where it was last verified and checks each entry.
    static func fetchRoster(_ roster: RosterState, api: SyncAPI, token: String) async throws(SyncError) -> RosterState {
        var roster = roster
        while true {
            let (head, entries) = try await api.roster(token: token, from: roster.count)
            // the server must never forget an entry this device has seen.
            guard head + 1 >= roster.count else { throw .rosterInvalid }
            for entry in entries { try roster.apply(entry.entry.data, entry.sig.data) }
            if roster.count > head { return roster }
            guard !entries.isEmpty else { throw .rosterInvalid }
        }
    }

    private func refreshRoster(token: String) async throws(SyncError) {
        state.roster = try await Self.fetchRoster(state.roster, api: api, token: token)
        save()
        guard state.roster.active(state.deviceID) != nil else { throw .removed }
    }

    // MARK: account

    public static func create(
        origin: URL, invite: String?, deviceName: String, stateURL: URL, vault: any SyncVault, hooks: SyncHooks
    ) async throws(SyncError) -> (SyncEngine, RecoveryCode) {
        let api = try SyncAPI(origin: origin)
        var inviteToken: Data?
        if let invite = invite?.trimmingCharacters(in: .whitespacesAndNewlines), !invite.isEmpty {
            guard let token = Data(base64URL: invite), token.count == 32 else {
                throw .server(status: 403, code: "forbidden")
            }
            inviteToken = token
        }
        let account = SyncCrypto.random(16)
        let deviceID = SyncCrypto.random(16)
        let keys = DeviceKeys.generate()
        let recovery = RecoveryCode.generate(accountID: account)
        let signer = try keys.signer()

        var roster = RosterState(accountID: account)
        let device = RosterState.NewDevice(
            id: deviceID, signPub: try keys.signPub, kemPub: try keys.kemPub, meta: DeviceMeta.encode(deviceName))
        let body = roster.body(
            .init(
                action: .genesis, device: device, signerID: deviceID,
                recovery: (
                    recovery.id, try recovery.signer().publicKey.x963Representation,
                    try recovery.agreer().publicKey.x963Representation
                )))
        let sig = try SyncCrypto.sign(body, with: signer)
        try roster.apply(body, sig)

        let epochKey = SymmetricKey(size: .bits256)
        let wrapped = [
            try wrap(
                epochKey, epoch: 1, account: account, to: (deviceID, device.kemPub), signer: signer, signerID: deviceID),
            try wrap(
                epochKey, epoch: 1, account: account, to: (roster.recoveryID, roster.recoveryKemPub), signer: signer,
                signerID: deviceID),
        ]
        try vault.saveDeviceKeys(keys)
        do {
            try await api.createAccount(id: account, invite: inviteToken, entry: body, sig: sig, keys: wrapped)
        } catch {
            vault.wipe()
            throw error
        }
        let state = SyncState(origin: origin, accountID: account, deviceID: deviceID, roster: roster)
        let engine = try SyncEngine(state: state, vault: vault, stateURL: stateURL, hooks: hooks)
        try await engine.remember(epochKey, epoch: 1)
        await engine.save()
        return (engine, recovery)
    }

    /// turns sync off on this device: local data stays, sync keys and state go.
    public func forget() {
        vault.wipe()
        try? FileManager.default.removeItem(at: stateURL)
        token = nil
        epochKeys = [:]
    }

    public func deleteAccount() async throws(SyncError) {
        try await withSession { token throws(SyncError) in
            try await refreshRoster(token: token)
            let message = SyncCrypto.message(
                .text("pounce/v1/delete-account"), .text(api.originText), .bytes(state.accountID),
                .bytes(state.deviceID), .bytes(state.roster.headHash))
            try await api.deleteAccount(
                token: token, sig: try SyncCrypto.sign(message, with: try deviceKeys().signer()))
        }
        forget()
    }

    // MARK: syncing

    /// one round of upload and download. a call while a round runs makes it go
    /// again instead of overlapping it.
    @discardableResult
    public func sync() async throws(SyncError) -> SyncReport {
        if running {
            rerun = true
            return SyncReport()
        }
        running = true
        defer { running = false }
        var report = SyncReport()
        repeat {
            rerun = false
            report = report + (try await withSession { token throws(SyncError) in try await round(token: token) })
        } while rerun
        if report.rejected > 0 { Self.log.error("rejected \(report.rejected) records") }
        return report
    }

    /// returns once records arrive or after about 25 seconds.
    public func waitForChanges() async throws(SyncError) {
        _ = try await withSession { token throws(SyncError) in
            try await api.changes(token: token, since: state.since, limit: 1, wait: 25).records.count
        }
    }

    /// records when local items changed, without the network; call it on every
    /// edit, since the later edit wins a conflict and offline edits wait.
    public func noteLocalChanges() async {
        if let snapshot = await hooks.snapshot() { stampEdits(snapshot) }
    }

    private func snapshot() async throws(SyncError) -> AppData {
        guard let snapshot = await hooks.snapshot() else { throw .notSetUp }
        return snapshot
    }

    private func round(token: String) async throws(SyncError) -> SyncReport {
        stampEdits(try await snapshot())
        try await refreshRoster(token: token)
        var report = try await pull(token: token)
        // a stale revision means another device wrote first: settle and go again.
        for _ in 0..<4 {
            let (pushed, stale) = try await push(token: token)
            report = report + pushed
            if !stale { break }
        }
        return report
    }

    private static var now: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    private struct Pending {
        var id: Data
        var payload: SyncPayload
        var hash: Data
    }

    /// local items that differ from what the server holds, and server items
    /// that are gone locally (as deletions).
    private func pending(_ snapshot: AppData) -> [Pending] {
        let local = SyncRecords.items(snapshot)
        let now = Self.now
        var out: [Pending] = []
        for (id, item) in local {
            let mark = state.marks[id.hex]
            guard item.hash != (mark?.deleted == false ? mark?.hash : nil) else { continue }
            var payload = item.payload
            payload.modified = state.edits[id.hex] ?? now
            out.append(Pending(id: id, payload: payload, hash: item.hash))
        }
        for (hex, mark) in state.marks where !mark.deleted {
            let gone: Bool
            switch mark.kind {
            case .key: gone = !(snapshot.identities.first { $0.id == mark.owner }?.syncsKey ?? false)
            case .password: gone = !(snapshot.hosts.first { $0.id == mark.owner }?.syncsPassword ?? false)
            default: gone = local[mark.id] == nil
            }
            if gone {
                out.append(
                    Pending(
                        id: mark.id,
                        payload: .tombstone(mark.kind, modified: state.edits[hex] ?? now, owner: mark.owner),
                        hash: Data()))
            }
        }
        return out
    }

    private func stampEdits(_ snapshot: AppData) {
        let now = Self.now
        let ids = Set(pending(snapshot).map(\.id.hex))
        state.edits = state.edits.filter { ids.contains($0.key) }
        for hex in ids where state.edits[hex] == nil { state.edits[hex] = now }
        save()
    }

    private func pull(token: String) async throws(SyncError) -> SyncReport {
        var report = SyncReport()
        while true {
            let page = try await api.changes(token: token, since: state.since)
            report = report + (try await receive(page.records, token: token))
            state.since = page.next
            save()
            if !page.more { return report }
        }
    }

    /// decides each incoming record against local edits (the later edit wins),
    /// applies what wins remotely and records what the server now holds.
    private func receive(_ records: [WireRecord], token: String) async throws(SyncError) -> SyncReport {
        var report = SyncReport()
        let snapshot = try await snapshot()
        let local = SyncRecords.items(snapshot)
        var changes: [SyncRecords.Change] = []
        var secrets: [SyncPayload] = []
        for record in records {
            let id = record.id.data
            let hex = id.hex
            let mark = state.marks[hex]
            // an echo of this device's own write, or a server going backwards.
            if let mark, record.rev <= mark.rev { continue }
            guard let blob = record.blob?.data,
                let payload = try? await open(blob, id: id, rev: record.rev, token: token),
                payload.isSecret ? payload.owner.map({ SyncRecords.secretID(payload.kind, owner: $0) }) == id : true
            else {
                report.rejected += 1
                continue
            }
            let remoteHash = payload.isDeleted ? Data() : SyncRecords.hash(payload)
            state.marks[hex] = .init(
                id: id, rev: record.rev, kind: payload.kind, hash: remoteHash, deleted: payload.isDeleted,
                owner: payload.owner)
            report.received += 1
            if payload.isSecret {
                if !payload.isDeleted { secrets.append(payload) }
                continue
            }
            let localHash = local[id]?.hash
            let known = mark?.deleted == false ? mark?.hash : nil
            if localHash == (payload.isDeleted ? nil : remoteHash) {
                state.edits[hex] = nil
                continue
            }
            if localHash != known, let edited = state.edits[hex],
                edited > payload.modified
                    || (edited == payload.modified && (localHash ?? Data()).hex > remoteHash.hex)
            {
                // the local edit is newer: it uploads over this revision next.
                continue
            }
            changes.append(.init(id: id, payload: payload, expected: localHash))
            state.edits[hex] = nil
        }
        if !changes.isEmpty {
            let batch = changes
            let skipped = await hooks.mutate { data in SyncRecords.apply(batch, to: &data) }
            for change in changes where !skipped.contains(change.id) && change.payload.isDeleted {
                guard let owner = UUID(data: change.id) else { continue }
                if change.payload.kind == .identity { vault.deleteIdentityKey(identity: owner) }
                if change.payload.kind == .host { vault.deletePassword(host: owner) }
            }
        }
        for secret in secrets { store(secret, identities: snapshot.identities) }
        save()
        return report
    }

    private func store(_ secret: SyncPayload, identities: [Identity]) {
        guard let owner = secret.owner else { return }
        do {
            if let key = secret.key, key.kind != .secureEnclaveP256 {
                // unknown identity: gated, the safer guess.
                let gated = identities.first { $0.id == owner }?.requiresBiometry ?? true
                try vault.saveIdentityKey(key, identity: owner, requireBiometry: gated)
            } else if let password = secret.password {
                try vault.savePassword(password, host: owner)
            }
        } catch {
            Self.log.error("couldn't store a synced secret: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open(_ blob: Data, id: Data, rev: UInt64, token: String) async throws(SyncError) -> SyncPayload {
        let key = try await epochKey(try SyncCrypto.envelopeEpoch(blob), token: token)
        let plaintext = try SyncCrypto.open(blob, key: key, account: state.accountID, record: id, rev: rev)
        do { return try JSONDecoder().decode(SyncPayload.self, from: plaintext) } catch { throw .decryptFailed }
    }

    /// uploads pending changes, 32 per batch. stale revisions are received like a
    /// pull, so the next pass re-uploads only what still wins.
    private func push(token: String) async throws(SyncError) -> (report: SyncReport, stale: Bool) {
        var report = SyncReport()
        var stale = false
        let pending = pending(try await snapshot())
        guard !pending.isEmpty else { return (report, false) }
        let epoch = state.roster.epoch
        let key = try await epochKey(epoch, token: token)
        for start in stride(from: 0, to: pending.count, by: 32) {
            let chunk = Array(pending[start..<min(start + 32, pending.count)])
            var writes: [SyncAPI.Write] = []
            for item in chunk {
                let ifMatch = state.marks[item.id.hex]?.rev ?? 0
                let blob = try SyncCrypto.seal(
                    try item.payload.encoded(), key: key, epoch: epoch, account: state.accountID, record: item.id,
                    rev: ifMatch + 1)
                writes.append(.init(id: B64(item.id), ifMatch: ifMatch, blob: B64(blob)))
            }
            switch try await api.batch(token: token, writes: writes) {
            case .written(let results):
                for (item, result) in zip(chunk, results) {
                    state.marks[item.id.hex] = .init(
                        id: item.id, rev: result.rev, kind: item.payload.kind, hash: item.hash,
                        deleted: item.payload.isDeleted, owner: item.payload.owner)
                    state.edits[item.id.hex] = nil
                }
                report.sent += results.count
            case .stale(let failed):
                // gone from the server: the next pass creates it again, or drops a deletion.
                for (id, current) in failed where current == nil { state.marks[id.hex] = nil }
                report = report + (try await receive(failed.compactMap(\.current), token: token))
                stale = true
            }
            save()
        }
        return (report, stale)
    }

    // MARK: secrets

    public func uploadKey(_ material: PrivateKeyMaterial, identity: UUID) async throws(SyncError) {
        try await upload(SyncPayload(kind: .key, modified: Self.now, owner: identity, key: material))
    }

    public func uploadPassword(_ password: String, host: UUID) async throws(SyncError) {
        try await upload(SyncPayload(kind: .password, modified: Self.now, owner: host, password: password))
    }

    /// an explicit user action, so it wins over whatever revision is there.
    private func upload(_ payload: SyncPayload) async throws(SyncError) {
        guard let owner = payload.owner else { return }
        let id = SyncRecords.secretID(payload.kind, owner: owner)
        try await withSession { token throws(SyncError) in
            try await refreshRoster(token: token)
            let epoch = state.roster.epoch
            let key = try await epochKey(epoch, token: token)
            for _ in 0..<3 {
                let ifMatch = state.marks[id.hex]?.rev ?? 0
                let blob = try SyncCrypto.seal(
                    try payload.encoded(), key: key, epoch: epoch, account: state.accountID, record: id,
                    rev: ifMatch + 1)
                switch try await api.batch(
                    token: token, writes: [.init(id: B64(id), ifMatch: ifMatch, blob: B64(blob))])
                {
                case .written(let results):
                    state.marks[id.hex] = .init(
                        id: id, rev: results.first?.rev ?? ifMatch + 1, kind: payload.kind,
                        hash: SyncRecords.hash(payload),
                        deleted: false, owner: owner)
                    save()
                    return
                case .stale(let failed):
                    if let current = failed.first?.current {
                        state.marks[id.hex] = .init(
                            id: id, rev: current.rev, kind: payload.kind, hash: Data(), deleted: false, owner: owner)
                    } else {
                        state.marks[id.hex] = nil
                    }
                }
            }
            throw .server(status: 412, code: "precondition_failed")
        }
    }

    // MARK: devices

    /// removes the device and rotates to a new epoch key in one roster append,
    /// so nothing is ever written under a key the removed device knows.
    public func removeDevice(_ id: Data) async throws(SyncError) {
        try await withSession { token throws(SyncError) in
            try await refreshRoster(token: token)
            let signer = try deviceKeys().signer()
            for _ in 0..<3 {
                var roster = state.roster
                guard roster.active(id) != nil, id != state.deviceID else { return }
                let remove = roster.body(.init(action: .removeDevice, target: id, signerID: state.deviceID))
                let removeSig = try SyncCrypto.sign(remove, with: signer)
                try roster.apply(remove, removeSig)
                let rotate = roster.body(.init(action: .rotate, epoch: roster.epoch + 1, signerID: state.deviceID))
                let rotateSig = try SyncCrypto.sign(rotate, with: signer)
                try roster.apply(rotate, rotateSig)
                let key = SymmetricKey(size: .bits256)
                let recipients =
                    roster.activeDevices.map { ($0.id, $0.kemPub) } + [(roster.recoveryID, roster.recoveryKemPub)]
                var keys: [WireKey] = []
                for recipient in recipients {
                    keys.append(
                        try Self.wrap(
                            key, epoch: roster.epoch, account: state.accountID, to: recipient, signer: signer,
                            signerID: state.deviceID))
                }
                let head = try await api.appendRoster(
                    token: token, head: state.roster.count - 1,
                    entries: [
                        WireEntry(entry: B64(remove), sig: B64(removeSig)),
                        WireEntry(entry: B64(rotate), sig: B64(rotateSig)),
                    ],
                    keys: keys)
                if head != nil {
                    state.roster = roster
                    try remember(key, epoch: roster.epoch)
                    save()
                    return
                }
                try await refreshRoster(token: token)
            }
            throw .server(status: 412, code: "precondition_failed")
        }
    }

    // MARK: pairing, existing device

    public func startPairing() async throws(SyncError) -> PairingInvite {
        let authToken = SyncCrypto.random(32)
        let keys = try deviceKeys()
        let id = try await withSession { token throws(SyncError) in
            try await api.createPairing(token: token, authTokenHash: SyncCrypto.sha256(authToken))
        }
        let invite = SyncCrypto.message(
            .text("pounce/v1/pair"), .text(api.originText), .bytes(state.accountID), .bytes(id), .bytes(authToken),
            .bytes(state.deviceID), .bytes(try keys.signPub))
        return PairingInvite(code: "pounce-pair:" + invite.base64URL, id: id)
    }

    /// waits for the other device to scan the code, then answers it with a signed
    /// nonce. cancelling the task stops the wait.
    public func waitForJoiner(_ invite: PairingInvite) async throws(SyncError) -> PairingRequest {
        let signer = try deviceKeys().signer()
        let deadline = Date.now.addingTimeInterval(600)
        while Date.now < deadline {
            let payload = try await withSession { token throws(SyncError) in
                try await api.pairingPayload(token: token, id: invite.id)
            }
            guard let payload else {
                try await Self.pause()
                continue
            }
            let device = try Self.parseJoin(payload)
            let nonce = SyncCrypto.random(32)
            let sig = try SyncCrypto.sign(
                Self.nonceMessage(account: state.accountID, pairing: invite.id, payload: payload, nonce: nonce),
                with: signer)
            try await withSession { token throws(SyncError) in
                try await api.pairingNonce(token: token, id: invite.id, nonce: nonce, sig: sig)
            }
            return PairingRequest(
                code: SyncCrypto.pairingCode(payload: payload, nonce: nonce),
                deviceName: (try? JSONDecoder().decode(DeviceMeta.self, from: device.meta))?.name ?? "Device",
                device: device)
        }
        throw .pairingExpired
    }

    /// adds the device with every epoch key it needs, in one roster append.
    public func approve(_ request: PairingRequest) async throws(SyncError) {
        try await withSession { token throws(SyncError) in
            try await refreshRoster(token: token)
            let signer = try deviceKeys().signer()
            for _ in 0..<3 {
                var roster = state.roster
                let body = roster.body(.init(action: .addDevice, device: request.device, signerID: state.deviceID))
                let sig = try SyncCrypto.sign(body, with: signer)
                try roster.apply(body, sig)
                var keys: [WireKey] = []
                for epoch in 1...max(roster.epoch, 1) {
                    keys.append(
                        try Self.wrap(
                            try await epochKey(epoch, token: token), epoch: epoch, account: state.accountID,
                            to: (request.device.id, request.device.kemPub), signer: signer, signerID: state.deviceID))
                }
                let head = try await api.appendRoster(
                    token: token, head: state.roster.count - 1, entries: [WireEntry(entry: B64(body), sig: B64(sig))],
                    keys: keys)
                if head != nil {
                    state.roster = roster
                    save()
                    return
                }
                try await refreshRoster(token: token)
            }
            throw .server(status: 412, code: "precondition_failed")
        }
    }

    static func nonceMessage(account: Data, pairing: Data, payload: Data, nonce: Data) -> Data {
        SyncCrypto.message(
            .text("pounce/v1/pairing-nonce"), .bytes(account), .bytes(pairing), .bytes(SyncCrypto.sha256(payload)),
            .bytes(nonce))
    }

    static func parseJoin(_ payload: Data) throws(SyncError) -> RosterState.NewDevice {
        var reader = SSHReader([UInt8](payload))
        do {
            guard try reader.readText() == "pounce/v1/join" else { throw SyncError.pairingFailed }
            let device = RosterState.NewDevice(
                id: Data(try reader.readString()), signPub: Data(try reader.readString()),
                kemPub: Data(try reader.readString()), meta: Data(try reader.readString()))
            guard reader.isAtEnd, device.id.count == 16, SyncCrypto.signingKey(device.signPub) != nil,
                SyncCrypto.agreementKey(device.kemPub) != nil, device.meta.count <= 1024
            else { throw SyncError.pairingFailed }
            return device
        } catch {
            throw .pairingFailed
        }
    }

    static func pause() async throws(SyncError) {
        do { try await Task.sleep(for: .seconds(2)) } catch { throw .network("cancelled") }
    }
}

// MARK: - joining and recovering

/// the new device's side of pairing: scan, show the code, wait to be added.
public actor SyncJoiner {
    let api: SyncAPI
    let origin: URL
    let accountID: Data
    let pairingID: Data
    let authToken: Data
    let inviterID: Data
    let inviterSignPub: Data
    let keys = DeviceKeys.generate()
    let deviceID = SyncCrypto.random(16)
    let deviceName: String

    public init(code: String, deviceName: String) throws(SyncError) {
        guard code.hasPrefix("pounce-pair:"), let raw = Data(base64URL: String(code.dropFirst(12))) else {
            throw .badPairingCode
        }
        var reader = SSHReader([UInt8](raw))
        do {
            guard try reader.readText() == "pounce/v1/pair" else { throw SyncError.badPairingCode }
            guard let origin = URL(string: try reader.readText()) else { throw SyncError.badPairingCode }
            self.origin = origin
            accountID = Data(try reader.readString())
            pairingID = Data(try reader.readString())
            authToken = Data(try reader.readString())
            inviterID = Data(try reader.readString())
            inviterSignPub = Data(try reader.readString())
            guard reader.isAtEnd, accountID.count == 16, pairingID.count == 16, authToken.count == 32,
                inviterID.count == 16, SyncCrypto.signingKey(inviterSignPub) != nil
            else { throw SyncError.badPairingCode }
        } catch {
            throw .badPairingCode
        }
        api = try SyncAPI(origin: origin)
        self.deviceName = deviceName
    }

    public var server: String { api.originText }

    /// sends this device's public keys and waits for the signed answer; returns
    /// the code to compare with the other device.
    public func join() async throws(SyncError) -> String {
        let payload = SyncCrypto.message(
            .text("pounce/v1/join"), .bytes(deviceID), .bytes(try keys.signPub), .bytes(try keys.kemPub),
            .bytes(DeviceMeta.encode(deviceName)))
        do {
            try await api.joinPairing(id: pairingID, authToken: authToken, payload: payload)
        } catch .server(status: 404, _) {
            throw .pairingExpired
        }
        let deadline = Date.now.addingTimeInterval(600)
        while Date.now < deadline {
            guard let answer = try await api.pollPairing(id: pairingID, authToken: authToken) else {
                try await SyncEngine.pause()
                continue
            }
            let message = SyncEngine.nonceMessage(
                account: accountID, pairing: pairingID, payload: payload, nonce: answer.nonce)
            guard answer.signer == inviterID, SyncCrypto.verify(answer.sig, for: message, publicKey: inviterSignPub)
            else { throw .pairingFailed }
            return SyncCrypto.pairingCode(payload: payload, nonce: answer.nonce)
        }
        throw .pairingExpired
    }

    /// waits until the other device approves, then checks the whole roster: the
    /// inviter from the qr code and this device must both be in it.
    public func finish(stateURL: URL, vault: any SyncVault, hooks: SyncHooks) async throws(SyncError) -> SyncEngine {
        let signer = try keys.signer()
        let deadline = Date.now.addingTimeInterval(600)
        var token: String?
        while token == nil {
            guard Date.now < deadline else { throw .pairingExpired }
            do {
                let nonce = try await api.challenge(account: accountID, device: deviceID)
                let sig = try SyncCrypto.sign(
                    SyncEngine.authMessage(origin: api.originText, account: accountID, device: deviceID, nonce: nonce),
                    with: signer)
                token = try await api.login(account: accountID, device: deviceID, nonce: nonce, sig: sig)
            } catch .server(status: 401, _) {
                try await SyncEngine.pause()
            }
        }
        guard let token else { throw .pairingExpired }
        let roster = try await SyncEngine.fetchRoster(RosterState(accountID: accountID), api: api, token: token)
        guard roster.active(inviterID)?.signPub == inviterSignPub,
            roster.active(deviceID)?.signPub == (try keys.signPub)
        else { throw .rosterInvalid }
        try vault.saveDeviceKeys(keys)
        let state = SyncState(origin: origin, accountID: accountID, deviceID: deviceID, roster: roster)
        let engine = try SyncEngine(state: state, vault: vault, stateURL: stateURL, hooks: hooks)
        await engine.persist()
        return engine
    }
}

extension SyncEngine {
    fileprivate func persist() { save() }

    /// signs in with the recovery code, then replaces every device with this one
    /// and rotates, all in one roster append. the code stays the same.
    public static func recover(
        origin: URL, code text: String, deviceName: String, stateURL: URL, vault: any SyncVault, hooks: SyncHooks
    ) async throws(SyncError) -> SyncEngine {
        guard let code = RecoveryCode(text: text) else { throw .badRecoveryCode }
        let api = try SyncAPI(origin: origin)
        let account = code.accountID
        let recoverySigner = try code.signer()
        let nonce: Data
        do {
            nonce = try await api.challenge(account: account, device: code.id)
        } catch .server(status: 401, _) {
            throw .badRecoveryCode
        }
        let token = try await api.login(
            account: account, device: code.id, nonce: nonce,
            sig: try SyncCrypto.sign(
                authMessage(origin: api.originText, account: account, device: code.id, nonce: nonce),
                with: recoverySigner))

        for _ in 0..<3 {
            let roster = try await fetchRoster(RosterState(accountID: account), api: api, token: token)
            guard roster.recoveryID == code.id, roster.recoverySignPub == recoverySigner.publicKey.x963Representation
            else { throw .rosterInvalid }
            var old: [UInt32: SymmetricKey] = [:]
            for epoch in 1...max(roster.epoch, 1) {
                guard let wire = try await api.key(token: token, epoch: epoch) else { throw .missingKey(epoch: epoch) }
                old[epoch] = try unwrap(wire, roster: roster, recipient: code.id, epoch: epoch, with: try code.agreer())
            }

            let keys = DeviceKeys.generate()
            let deviceID = SyncCrypto.random(16)
            let signer = try keys.signer()
            let device = RosterState.NewDevice(
                id: deviceID, signPub: try keys.signPub, kemPub: try keys.kemPub, meta: DeviceMeta.encode(deviceName))
            var next = roster
            let recover = next.body(.init(action: .recover, device: device, signerID: code.id))
            let recoverSig = try SyncCrypto.sign(recover, with: recoverySigner)
            try next.apply(recover, recoverSig)
            let rotate = next.body(.init(action: .rotate, epoch: next.epoch + 1, signerID: deviceID))
            let rotateSig = try SyncCrypto.sign(rotate, with: signer)
            try next.apply(rotate, rotateSig)
            old[next.epoch] = SymmetricKey(size: .bits256)

            var wrapped: [WireKey] = []
            for (epoch, key) in old.sorted(by: { $0.key < $1.key }) {
                wrapped.append(
                    try wrap(
                        key, epoch: epoch, account: account, to: (deviceID, device.kemPub), signer: signer,
                        signerID: deviceID))
            }
            if let newest = old[next.epoch] {
                wrapped.append(
                    try wrap(
                        newest, epoch: next.epoch, account: account, to: (next.recoveryID, next.recoveryKemPub),
                        signer: signer, signerID: deviceID))
            }
            let head = try await api.appendRoster(
                token: token, head: roster.count - 1,
                entries: [
                    WireEntry(entry: B64(recover), sig: B64(recoverSig)),
                    WireEntry(entry: B64(rotate), sig: B64(rotateSig)),
                ],
                keys: wrapped)
            guard head != nil else { continue }

            try vault.saveDeviceKeys(keys)
            try vault.saveEpochKeys(old.mapValues { $0.withUnsafeBytes { Data($0) } })
            let state = SyncState(origin: origin, accountID: account, deviceID: deviceID, roster: next)
            let engine = try SyncEngine(state: state, vault: vault, stateURL: stateURL, hooks: hooks)
            await engine.persist()
            return engine
        }
        throw .server(status: 412, code: "precondition_failed")
    }
}
