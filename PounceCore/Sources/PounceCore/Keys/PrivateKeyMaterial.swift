import CryptoKit
import Foundation
import NIOSSH
import Security

/// `data` is the ed25519 seed, the fixed-width ecdsa scalar, a pkcs#1 rsa der, or for
/// `.secureEnclaveP256` an opaque `dataRepresentation` that only this device's enclave can use
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
        case .rsa:
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ]
            guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
                throw .malformed
            }
            return try keyAttempt { try NIOSSHPrivateKey(rsaKey: key) }
        case .secureEnclaveP256:
            guard SecureEnclave.isAvailable else { throw .secureEnclaveUnavailable }
            do {
                return NIOSSHPrivateKey(secureEnclaveP256Key: try .init(dataRepresentation: data))
            } catch {
                throw .secureEnclaveFailed(error.localizedDescription)
            }
        }
    }

    public static func generateEd25519(comment: String) -> PrivateKeyMaterial {
        PrivateKeyMaterial(kind: .ed25519, data: Curve25519.Signing.PrivateKey().rawRepresentation, comment: comment)
    }

    /// signing always needs the device unlocked, and with `requireBiometry` a face id or
    /// touch id match against current enrolment (re-enrolling invalidates the key)
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
