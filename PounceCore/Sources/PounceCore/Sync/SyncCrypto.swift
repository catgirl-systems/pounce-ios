import CryptoKit
import Foundation

/// a value in a signed or hashed message: strings and bytes length-prefixed,
/// integers big-endian, as pounce-sync's `message` encodes them.
enum WireField {
    case text(String)
    case bytes(Data)
    case u32(UInt32)
    case u64(UInt64)
}

enum SyncCrypto {
    static func message(_ fields: WireField...) -> Data { message(fields) }

    static func message(_ fields: [WireField]) -> Data {
        var writer = SSHWriter()
        for field in fields {
            switch field {
            case .text(let value): writer.writeString(value)
            case .bytes(let value): writer.writeString(value)
            case .u32(let value): writer.writeUInt32(value)
            case .u64(let value): writer.writeUInt64(value)
            }
        }
        return Data(writer.bytes)
    }

    static func random(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    // MARK: signatures

    /// the p-256 group order, big-endian.
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]

    private static let halfOrder: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 32)
        var carry: UInt8 = 0
        for i in 0..<32 {
            out[i] = (order[i] >> 1) | carry
            carry = (order[i] & 1) << 7
        }
        return out
    }()

    private static func greater(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<32 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    /// raw `r | s` with s in the lower half of the order: the server accepts only
    /// that form, so every signed roster entry has one encoding and one hash.
    static func sign(_ message: Data, with key: P256.Signing.PrivateKey) throws(SyncError) -> Data {
        guard let raw = try? key.signature(for: message).rawRepresentation, raw.count == 64 else {
            throw .crypto
        }
        let s = [UInt8](raw.suffix(32))
        guard greater(s, halfOrder) else { return raw }
        var flipped = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in (0..<32).reversed() {
            let d = Int(order[i]) - Int(s[i]) - borrow
            flipped[i] = UInt8((d + 256) & 0xFF)
            borrow = d < 0 ? 1 : 0
        }
        return raw.prefix(32) + Data(flipped)
    }

    static func verify(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard signature.count == 64, !greater([UInt8](signature.suffix(32)), halfOrder),
            let key = signingKey(publicKey),
            let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(sig, for: message)
    }

    /// only the 65-byte uncompressed form, which is what the server checks.
    static func signingKey(_ raw: Data) -> P256.Signing.PublicKey? {
        guard raw.count == 65, raw.first == 4 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: raw)
    }

    static func agreementKey(_ raw: Data) -> P256.KeyAgreement.PublicKey? {
        guard raw.count == 65, raw.first == 4 else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: raw)
    }

    // MARK: wrapped epoch keys

    private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    private static func wrapInfo(account: Data, recipient: Data, epoch: UInt32) -> Data {
        message(.text("pounce/v1/wrap"), .bytes(account), .bytes(recipient), .u32(epoch))
    }

    /// hpke base mode to the recipient's agreement key: `encapsulated key | ciphertext`.
    static func wrap(_ key: SymmetricKey, to agreementKey: Data, account: Data, recipient: Data, epoch: UInt32)
        throws(SyncError) -> Data
    {
        guard let publicKey = Self.agreementKey(agreementKey) else { throw .crypto }
        do {
            var sender = try HPKE.Sender(
                recipientKey: publicKey, ciphersuite: suite,
                info: wrapInfo(account: account, recipient: recipient, epoch: epoch))
            let sealed = try key.withUnsafeBytes { try sender.seal(Data($0)) }
            return sender.encapsulatedKey + sealed
        } catch {
            throw .crypto
        }
    }

    static func unwrap(
        _ blob: Data, with privateKey: P256.KeyAgreement.PrivateKey, account: Data, recipient: Data, epoch: UInt32
    ) throws(SyncError) -> SymmetricKey {
        let blob = Data(blob)
        guard blob.count > 65 else { throw .decryptFailed }
        do {
            var receiver = try HPKE.Recipient(
                privateKey: privateKey, ciphersuite: suite,
                info: wrapInfo(account: account, recipient: recipient, epoch: epoch),
                encapsulatedKey: blob.prefix(65))
            let raw = try receiver.open(blob.dropFirst(65))
            guard raw.count == 32 else { throw SyncError.decryptFailed }
            return SymmetricKey(data: raw)
        } catch {
            throw .decryptFailed
        }
    }

    // MARK: record envelopes

    /// `1 | epoch` then an aes-gcm box. the header, account, record id and revision
    /// are authenticated, so the server can't move a blob to another record or
    /// serve an older revision as a newer one.
    static func seal(_ plaintext: Data, key: SymmetricKey, epoch: UInt32, account: Data, record: Data, rev: UInt64)
        throws(SyncError) -> Data
    {
        let header = Data([1]) + Data(epoch.bigEndianBytes)
        guard
            let box = try? AES.GCM.seal(
                padded(plaintext), using: key,
                authenticating: header + recordAD(account: account, record: record, rev: rev)),
            let combined = box.combined
        else { throw .crypto }
        return header + combined
    }

    static func envelopeEpoch(_ envelope: Data) throws(SyncError) -> UInt32 {
        let envelope = Data(envelope)
        guard envelope.count >= 33, envelope[0] == 1 else { throw .decryptFailed }
        return envelope[1..<5].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func open(_ envelope: Data, key: SymmetricKey, account: Data, record: Data, rev: UInt64)
        throws(SyncError) -> Data
    {
        let envelope = Data(envelope)
        _ = try envelopeEpoch(envelope)
        let header = envelope.prefix(5)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(5))
            return try AES.GCM.open(
                box, using: key, authenticating: header + recordAD(account: account, record: record, rev: rev))
        } catch {
            throw .decryptFailed
        }
    }

    private static func recordAD(account: Data, record: Data, rev: UInt64) -> Data {
        message(.text("pounce/v1/record"), .bytes(account), .bytes(record), .u64(rev))
    }

    /// json allows trailing whitespace, so spaces up to a multiple of 256 bytes
    /// hide each record's exact size from the server.
    private static func padded(_ plaintext: Data) -> Data {
        let target = (plaintext.count / 256 + 1) * 256
        return plaintext + Data(repeating: 0x20, count: target - plaintext.count)
    }

    // MARK: pairing

    /// six digits both devices show; a server that swapped the joining device's
    /// keys can't also match the code, because the nonce is fixed after the join.
    static func pairingCode(payload: Data, nonce: Data) -> String {
        let hash = sha256(message(.text("pounce/v1/sas"), .bytes(sha256(payload)), .bytes(nonce)))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(value).leftPad(to: 6)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

extension String {
    fileprivate func leftPad(to count: Int) -> String {
        String(repeating: "0", count: max(0, count - self.count)) + self
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        guard !text.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        self.init(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
