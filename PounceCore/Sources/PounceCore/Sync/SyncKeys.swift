import CryptoKit
import Foundation

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case badServerURL
    case network(String)
    case server(status: Int, code: String)
    case malformed
    case crypto
    case rosterInvalid
    case removed
    case badRecoveryCode
    case badPairingCode
    case pairingExpired
    case pairingFailed
    case missingKey(epoch: UInt32)
    case decryptFailed
    case notSetUp
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .badServerURL: "The server address must start with https://."
        case .network(let reason): "Couldn't reach the sync server: \(reason)"
        case .server(let status, let code): Self.describe(status: status, code: code)
        case .malformed: "The sync server sent a reply pounce doesn't understand."
        case .crypto: "Encryption failed on this device."
        case .rosterInvalid:
            "The sync server's list of devices doesn't verify. It may have been tampered with, so sync has stopped."
        case .removed: "This device was removed from the sync account."
        case .badRecoveryCode: "That recovery code isn't valid. Check it for typos."
        case .badPairingCode: "That isn't a pounce pairing code."
        case .pairingExpired: "The pairing code expired. Start again on the other device."
        case .pairingFailed: "The other device's answer didn't verify, so pairing stopped. Start again."
        case .missingKey(let epoch): "The key for epoch \(epoch) isn't available to this device."
        case .decryptFailed: "Some synced data couldn't be decrypted or verified."
        case .notSetUp: "Sync isn't set up."
        case .keychain(let reason): reason
        }
    }

    private static func describe(status: Int, code: String) -> String {
        switch code {
        case "registration_closed": "This server doesn't accept new accounts."
        case "forbidden" where status == 403: "The server refused: check the invite code."
        case "quota_exceeded": "The sync account is full."
        case "rate_limited": "The sync server is busy. Try again in a minute."
        case "unauthorized": "The sync server didn't accept this device."
        case "not_found": "The sync server doesn't know about this."
        default: "The sync server answered \(status) (\(code))."
        }
    }
}

/// a device's private keys, kept in the keychain: raw p-256 scalars.
public struct DeviceKeys: Codable, Sendable {
    public var signing: Data
    public var agreement: Data

    static func generate() -> DeviceKeys {
        DeviceKeys(
            signing: P256.Signing.PrivateKey().rawRepresentation,
            agreement: P256.KeyAgreement.PrivateKey().rawRepresentation)
    }

    func signer() throws(SyncError) -> P256.Signing.PrivateKey {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: signing) else { throw .crypto }
        return key
    }

    func agreer() throws(SyncError) -> P256.KeyAgreement.PrivateKey {
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: agreement) else { throw .crypto }
        return key
    }

    var signPub: Data { get throws(SyncError) { try signer().publicKey.x963Representation } }
    var kemPub: Data { get throws(SyncError) { try agreer().publicKey.x963Representation } }
}

/// the account id and a 32-byte secret with a 2-byte check, as 80 crockford
/// base32 characters in groups of five. the recovery keys derive from it.
public struct RecoveryCode: Sendable, Equatable {
    public let accountID: Data
    let secret: Data

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(accountID: Data) -> RecoveryCode {
        RecoveryCode(accountID: accountID, secret: SyncCrypto.random(32))
    }

    private init(accountID: Data, secret: Data) {
        self.accountID = accountID
        self.secret = secret
    }

    public var text: String {
        let body = accountID + secret
        let bytes = [UInt8](body + SyncCrypto.sha256(body).prefix(2))
        var chars: [Character] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars.append(Self.alphabet[(buffer >> bits) & 31])
            }
        }
        return stride(from: 0, to: chars.count, by: 5).map { String(chars[$0..<min($0 + 5, chars.count)]) }
            .joined(separator: "-")
    }

    /// forgiving about case, spaces, dashes and the letters crockford folds.
    public init?(text: String) {
        var buffer = 0
        var bits = 0
        var bytes: [UInt8] = []
        for raw in text.uppercased() where !raw.isWhitespace && raw != "-" {
            let char: Character =
                switch raw {
                case "O": "0"
                case "I", "L": "1"
                default: raw
                }
            guard let value = Self.alphabet.firstIndex(of: char) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        guard bytes.count == 50 else { return nil }
        let body = Data(bytes.prefix(48))
        guard SyncCrypto.sha256(body).prefix(2) == Data(bytes.suffix(2)) else { return nil }
        self.init(accountID: body.prefix(16), secret: body.suffix(32))
    }

    var id: Data { derive("id", count: 16) }

    func signer() throws(SyncError) -> P256.Signing.PrivateKey {
        // a derived scalar is out of range with odds of about 2^-32; the counter moves past it.
        for attempt in 0..<8 {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: derive("sign/\(attempt)", count: 32)) {
                return key
            }
        }
        throw .crypto
    }

    func agreer() throws(SyncError) -> P256.KeyAgreement.PrivateKey {
        for attempt in 0..<8 {
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: derive("kem/\(attempt)", count: 32)) {
                return key
            }
        }
        throw .crypto
    }

    private func derive(_ label: String, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: accountID,
            info: Data("pounce/v1/recovery/\(label)".utf8),
            outputByteCount: count
        ).withUnsafeBytes { Data($0) }
    }
}

/// where the sync engine keeps its secrets. the app uses the keychain.
public protocol SyncVault: Sendable {
    func deviceKeys() throws(SyncError) -> DeviceKeys?
    func saveDeviceKeys(_ keys: DeviceKeys) throws(SyncError)
    func epochKeys() -> [UInt32: Data]
    func saveEpochKeys(_ keys: [UInt32: Data]) throws(SyncError)
    func saveIdentityKey(_ material: PrivateKeyMaterial, identity: UUID, requireBiometry: Bool) throws(SyncError)
    func deleteIdentityKey(identity: UUID)
    func savePassword(_ password: String, host: UUID) throws(SyncError)
    func deletePassword(host: UUID)
    /// the device and epoch keys only; synced keys and passwords stay.
    func wipe()
}
