import CryptoKit
import Foundation
import NIOSSH
import Security

/// `data` is the ed25519 seed, the fixed-width ecdsa scalar, a pkcs#1 rsa der, or
/// for `.secureEnclaveP256` an opaque `dataRepresentation` handle that only this
/// device's secure enclave can use.
public struct PrivateKeyMaterial: Sendable, Hashable, Codable {
    public var kind: KeyKind
    public var data: Data
    public var comment: String

    public init(kind: KeyKind, data: Data, comment: String = "") {
        self.kind = kind
        self.data = data
        self.comment = comment
    }

    public var publicKey: SSHPublicKey {
        get throws(KeyError) {
            var key = try SSHPublicKey(sshPrivateKey().publicKey)
            key.comment = comment
            return key
        }
    }

    public func sshPrivateKey() throws(KeyError) -> NIOSSHPrivateKey {
        switch kind {
        case .ed25519: return try NIOSSHPrivateKey(ed25519Key: keyAttempt { try .init(rawRepresentation: data) })
        case .ecdsaP256: return try NIOSSHPrivateKey(p256Key: keyAttempt { try .init(rawRepresentation: data) })
        case .ecdsaP384: return try NIOSSHPrivateKey(p384Key: keyAttempt { try .init(rawRepresentation: data) })
        case .ecdsaP521: return try NIOSSHPrivateKey(p521Key: keyAttempt { try .init(rawRepresentation: data) })
        case .rsa: return try keyAttempt { try NIOSSHPrivateKey(rsaKey: rsaSecKey()) }
        case .secureEnclaveP256:
            guard SecureEnclave.isAvailable else { throw .secureEnclaveUnavailable }
            do {
                return NIOSSHPrivateKey(secureEnclaveP256Key: try .init(dataRepresentation: data))
            } catch {
                throw .secureEnclaveFailed(error.localizedDescription)
            }
        }
    }

    /// for `SecKeyCreateSignature` with rsa-sha2-256/512. only valid for `.rsa`.
    public func rsaSecKey() throws(KeyError) -> SecKey {
        guard kind == .rsa else { throw .wrongKeyKind }
        return try Self.makeRSAKey(pkcs1: data)
    }

    static func makeRSAKey(pkcs1: Data) throws(KeyError) -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            throw .malformed
        }
        return key
    }

    public static func generateEd25519(comment: String) -> PrivateKeyMaterial {
        PrivateKeyMaterial(kind: .ed25519, data: Curve25519.Signing.PrivateKey().rawRepresentation, comment: comment)
    }

    /// signing always needs the device unlocked, and with `requireBiometry` a face id /
    /// touch id match against current enrolment (re-enrolling invalidates the key).
    public static func generateSecureEnclaveP256(comment: String, requireBiometry: Bool) throws(KeyError)
        -> PrivateKeyMaterial
    {
        guard SecureEnclave.isAvailable else { throw .secureEnclaveUnavailable }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requireBiometry { flags.insert(.biometryCurrentSet) }
        var error: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
        else {
            let reason = error.map { $0.takeRetainedValue().localizedDescription } ?? "access control"
            throw .secureEnclaveFailed(reason)
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            return PrivateKeyMaterial(kind: .secureEnclaveP256, data: key.dataRepresentation, comment: comment)
        } catch {
            throw .secureEnclaveFailed(error.localizedDescription)
        }
    }
}
