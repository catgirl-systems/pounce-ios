import Foundation

public enum KeyKind: String, Codable, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa
    case secureEnclaveP256

    var curve: (name: String, scalarSize: Int, bits: Int)? {
        switch self {
        case .ecdsaP256, .secureEnclaveP256: ("nistp256", 32, 256)
        case .ecdsaP384: ("nistp384", 48, 384)
        case .ecdsaP521: ("nistp521", 66, 521)
        case .ed25519, .rsa: nil
        }
    }

    static let ecdsaKinds: [KeyKind] = [.ecdsaP256, .ecdsaP384, .ecdsaP521]

    init?(curveName: String) {
        guard let kind = Self.ecdsaKinds.first(where: { $0.curve?.name == curveName }) else { return nil }
        self = kind
    }

    /// always `ssh-rsa` for rsa: rsa-sha2-256/512 is negotiated separately
    var algorithm: String {
        if let curve { return "ecdsa-sha2-" + curve.name }
        return self == .rsa ? "ssh-rsa" : "ssh-ed25519"
    }
}

public enum KeyError: Error, LocalizedError, Equatable, Sendable {
    case passphraseRequired
    case wrongPassphrase
    case unsupported(String)
    case malformed
    case unrecognizedFormat
    case publicKeyOnly
    case secureEnclaveUnavailable
    case secureEnclaveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .passphraseRequired: "This key is protected by a passphrase. Enter it to import the key."
        case .wrongPassphrase: "The passphrase is incorrect."
        case .unsupported(let what): "This key isn't supported: \(what)."
        case .malformed: "The key data is damaged or incomplete. Try copying it again."
        case .unrecognizedFormat: "This doesn't look like a private key."
        case .publicKeyOnly: "This is a public key. Import the private key instead (the file without .pub)."
        case .secureEnclaveUnavailable: "This device has no Secure Enclave."
        case .secureEnclaveFailed(let reason): "The Secure Enclave couldn't use the key: \(reason)."
        }
    }

    static let dsaObsolete = KeyError.unsupported("DSA keys are obsolete and disabled in modern OpenSSH")
}

/// any cryptokit or security error here means the key bytes are bad
func keyAttempt<T>(_ body: () throws -> T) throws(KeyError) -> T {
    do { return try body() } catch { throw .malformed }
}
