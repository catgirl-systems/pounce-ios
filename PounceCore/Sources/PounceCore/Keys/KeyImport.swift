import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum KeyImport {
    /// openssh-key-v1 (plain, or aes ctr/gcm with bcrypt kdf) or unencrypted pem
    /// (pkcs#1, sec1, pkcs#8), which carries no comment. tolerates whitespace, crlf
    /// and junk lines around the armor.
    public static func parse(_ text: String, passphrase: String?) throws(KeyError) -> PrivateKeyMaterial {
        if text.contains("PuTTY-User-Key-File") {
            throw .unsupported("PuTTY .ppk files need converting first (PuTTYgen: Conversions › Export OpenSSH key)")
        }
        guard let block = PEMBlock(text) else {
            if (try? SSHPublicKey(authorizedKeysLine: text)) != nil { throw .publicKeyOnly }
            throw .unrecognizedFormat
        }
        switch block.label {
        case "OPENSSH PRIVATE KEY":
            return try OpenSSHKeyFile(block.body).decode(passphrase: passphrase)
        case "RSA PRIVATE KEY":
            guard !block.isEncrypted else { throw encryptedPEM }
            return try rsa(pkcs1: block.body, comment: "")
        case "EC PRIVATE KEY":
            guard !block.isEncrypted else { throw encryptedPEM }
            return try ec(sec1: block.body, curve: nil)
        case "PRIVATE KEY":
            return try pkcs8(block.body)
        case "ENCRYPTED PRIVATE KEY":
            throw encryptedPEM
        case "DSA PRIVATE KEY":
            throw .dsaObsolete
        case let label where label.contains("PUBLIC KEY"):
            throw .publicKeyOnly
        default:
            throw .unrecognizedFormat
        }
    }

    /// lets the ui ask before trying. false for encrypted pem, which `parse` rejects
    /// as unsupported whatever the passphrase.
    public static func needsPassphrase(_ text: String) -> Bool {
        guard let block = PEMBlock(text), block.label == "OPENSSH PRIVATE KEY",
            let file = try? OpenSSHKeyFile(block.body)
        else { return false }
        return file.cipherName != "none"
    }

    private static let encryptedPEM = KeyError.unsupported(
        "encrypted PEM keys can't be read; convert with `ssh-keygen -p -f <key>` to the OpenSSH format")

    // MARK: - pem armor

    /// body and headers between a begin/end pair, anywhere in the text. line breaks
    /// may have been flattened to spaces.
    private struct PEMBlock {
        let label: String
        let body: [UInt8]
        let isEncrypted: Bool

        init?(_ text: String) {
            guard let begin = text.range(of: "-----BEGIN "),
                let labelEnd = text.range(of: "-----", range: begin.upperBound..<text.endIndex)
            else { return nil }
            let label = String(text[begin.upperBound..<labelEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard let end = text.range(of: "-----END \(label)-----", range: labelEnd.upperBound..<text.endIndex) else {
                return nil
            }
            var base64 = ""
            var encrypted = false
            let inner = text[labelEnd.upperBound..<end.lowerBound]
            for line in inner.split(whereSeparator: \.isNewline) {
                // rfc 1421 headers such as `Proc-Type: 4,ENCRYPTED` and `DEK-Info: ...`.
                if line.contains(":") {
                    if line.contains("ENCRYPTED") { encrypted = true }
                    continue
                }
                base64 += line.filter { !$0.isWhitespace }
            }
            guard let data = Data(base64Encoded: SSHPublicKey.padded(base64)) else { return nil }
            self.label = label
            self.body = Array(data)
            self.isEncrypted = encrypted || label.hasPrefix("ENCRYPTED")
        }
    }

    // MARK: - pkcs#1 / sec1 / pkcs#8

    private static let oidRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidEd25519: [UInt8] = [0x2B, 0x65, 0x70]
    private static let oidP256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidP384: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
    private static let oidP521: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]

    /// security validates the pkcs#1 `RSAPrivateKey`; the bytes are kept as-is.
    static func rsa(pkcs1: [UInt8], comment: String) throws(KeyError) -> PrivateKeyMaterial {
        let data = Data(pkcs1)
        _ = try PrivateKeyMaterial.makeRSAKey(pkcs1: data)
        let material = PrivateKeyMaterial(kind: .rsa, data: data, comment: comment)
        _ = try material.publicKey
        return material
    }

    /// `ECPrivateKey ::= SEQUENCE { version(1), privateKey OCTET STRING,`
    ///   `[0] parameters OPTIONAL, [1] publicKey OPTIONAL }`
    private static func ec(sec1: [UInt8], curve outerCurve: KeyKind?) throws(KeyError) -> PrivateKeyMaterial {
        var fields = try DERReader.versionedSequence(sec1)
        let scalar = try fields.read(DERReader.octetString)
        var curve = outerCurve
        var publicPoint: [UInt8]?
        while !fields.isAtEnd {
            let element = try fields.read()
            var tagged = DERReader(element.content)
            switch element.tag {
            case 0xA0: curve = try ecCurve(parameters: tagged.read())
            case 0xA1:
                // bit string: the first byte is the unused-bit count (always 0 here).
                publicPoint = Array(try tagged.read(DERReader.bitString).dropFirst())
            default: break
            }
        }
        // no parameters anywhere: the scalar's width is the only hint left (a p-521
        // scalar may have lost its leading zero byte).
        let width = scalar.count == 65 ? 66 : scalar.count
        guard let kind = curve ?? KeyKind.ecdsaKinds.first(where: { $0.curve?.scalarSize == width }) else {
            throw .unsupported("unknown elliptic curve")
        }
        let material = try ecMaterial(kind: kind, scalar: scalar, comment: "")
        if let publicPoint, try ecPoint(material) != publicPoint { throw .malformed }
        return material
    }

    /// normally a named-curve oid, but openssh linked against openssl 3 writes explicit
    /// `ECParameters` in `-m PEM` files, so the field prime tells the nist curves apart.
    private static func ecCurve(parameters: (tag: UInt8, content: [UInt8])) throws(KeyError) -> KeyKind {
        switch parameters.tag {
        case DERReader.objectIdentifier:
            switch parameters.content {
            case oidP256: return .ecdsaP256
            case oidP384: return .ecdsaP384
            case oidP521: return .ecdsaP521
            default: throw unsupportedCurve
            }
        case DERReader.sequence:
            // `ECParameters ::= SEQUENCE { version, FieldID ::= SEQUENCE { fieldType, prime }, ... }`
            var fields = DERReader(parameters.content)
            _ = try fields.read(DERReader.integer)
            var fieldID = DERReader(try fields.read(DERReader.sequence))
            guard try fieldID.read(DERReader.objectIdentifier) == oidPrimeField else { throw unsupportedCurve }
            switch try fieldID.readUnsignedInteger() {
            case primeP256: return .ecdsaP256
            case primeP384: return .ecdsaP384
            case primeP521: return .ecdsaP521
            default: throw unsupportedCurve
            }
        default:
            throw unsupportedCurve
        }
    }

    private static let unsupportedCurve = KeyError.unsupported("only NIST P-256, P-384 and P-521 curves work with SSH")
    private static let oidPrimeField: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x01, 0x01]
    private static let primeP256: [UInt8] =
        [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 12)
        + [UInt8](repeating: 0xFF, count: 12)
    private static let primeP384: [UInt8] =
        [UInt8](repeating: 0xFF, count: 31) + [0xFE] + [UInt8](repeating: 0xFF, count: 4)
        + [UInt8](repeating: 0, count: 8)
        + [UInt8](repeating: 0xFF, count: 4)
    private static let primeP521: [UInt8] = [0x01] + [UInt8](repeating: 0xFF, count: 65)

    /// `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING, ... }`
    private static func pkcs8(_ der: [UInt8]) throws(KeyError) -> PrivateKeyMaterial {
        var fields = try DERReader.versionedSequence(der)
        var algorithm = DERReader(try fields.read(DERReader.sequence))
        let oid = try algorithm.read(DERReader.objectIdentifier)
        let privateKey = try fields.read(DERReader.octetString)
        switch oid {
        case oidRSA:
            return try rsa(pkcs1: privateKey, comment: "")
        case oidECPublicKey:
            let curve = algorithm.isAtEnd ? nil : try ecCurve(parameters: algorithm.read())
            return try ec(sec1: privateKey, curve: curve)
        case oidEd25519:
            // `CurvePrivateKey ::= OCTET STRING` (the 32-byte seed), wrapped once more.
            var inner = DERReader(privateKey)
            let seed = try inner.read(DERReader.octetString)
            guard seed.count == 32 else { throw .malformed }
            let material = PrivateKeyMaterial(kind: .ed25519, data: Data(seed))
            _ = try material.publicKey
            return material
        default:
            throw .unsupported("this PKCS#8 key algorithm")
        }
    }

    /// accepts any scalar width: mpints drop or add leading zeros.
    static func ecMaterial(kind: KeyKind, scalar: [UInt8], comment: String) throws(KeyError) -> PrivateKeyMaterial {
        guard let size = kind.curve?.scalarSize else { throw .wrongKeyKind }
        guard let raw = scalar.leftPadded(to: size) else { throw .malformed }
        let material = PrivateKeyMaterial(kind: kind, data: Data(raw), comment: comment)
        _ = try material.publicKey
        return material
    }

    /// uncompressed public point: 0x04 || x || y.
    static func ecPoint(_ material: PrivateKeyMaterial) throws(KeyError) -> [UInt8] {
        var reader = SSHReader(Array(try material.publicKey.blob))
        _ = try reader.readString()
        _ = try reader.readString()
        return try reader.readString()
    }
}

// MARK: - openssh-key-v1

/// the default `ssh-keygen` container (`PROTOCOL.key`): magic, cipher, kdf, kdf options,
/// key count, public key, then the possibly encrypted private section and aead tag.
private struct OpenSSHKeyFile {
    let cipherName: String
    let kdfName: String
    let kdfOptions: [UInt8]
    let publicBlob: [UInt8]
    let privateSection: [UInt8]
    let trailer: [UInt8]

    init(_ bytes: [UInt8]) throws(KeyError) {
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard bytes.starts(with: magic) else { throw .malformed }
        var reader = SSHReader(Array(bytes.dropFirst(magic.count)))
        cipherName = try reader.readText()
        kdfName = try reader.readText()
        kdfOptions = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw .unsupported("files holding several keys") }
        publicBlob = try reader.readString()
        privateSection = try reader.readString()
        trailer = reader.remaining
    }

    /// ciphers openssh can write that commoncrypto/cryptokit can undo.
    private enum Cipher {
        case none
        case ctr(keyLength: Int)
        case gcm(keyLength: Int)

        init(_ name: String) throws(KeyError) {
            switch name {
            case "none": self = .none
            case "aes128-ctr": self = .ctr(keyLength: 16)
            case "aes192-ctr": self = .ctr(keyLength: 24)
            case "aes256-ctr": self = .ctr(keyLength: 32)
            case "aes128-gcm@openssh.com": self = .gcm(keyLength: 16)
            case "aes256-gcm@openssh.com": self = .gcm(keyLength: 32)
            default: throw .unsupported("the \(name) cipher; re-encrypt with `ssh-keygen -p -Z aes256-ctr`")
            }
        }
    }

    func decode(passphrase: String?) throws(KeyError) -> PrivateKeyMaterial {
        let cipher = try Cipher(cipherName)
        let plaintext: [UInt8]
        switch cipher {
        case .none:
            plaintext = privateSection
        case .ctr(let keyLength), .gcm(let keyLength):
            guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
            guard kdfName == "bcrypt" else { throw .unsupported("the \(kdfName) key derivation") }
            var options = SSHReader(kdfOptions)
            let salt = try options.readString()
            let rounds = Int(try options.readUInt32())
            // each round costs tens of milliseconds on a phone; refuse absurd counts
            // rather than hang on a crafted file.
            guard rounds <= 10_000 else { throw .unsupported("more than 10000 KDF rounds") }
            guard privateSection.count % 16 == 0 else { throw .malformed }
            if case .ctr = cipher {
                let derived = try BcryptPBKDF.deriveKey(
                    password: Array(passphrase.utf8), salt: salt, rounds: rounds, keyLength: keyLength + 16)
                plaintext = try Self.aesCTR(
                    key: Array(derived[..<keyLength]), iv: Array(derived[keyLength...]), data: privateSection)
            } else {
                guard trailer.count >= 16 else { throw .malformed }
                let derived = try BcryptPBKDF.deriveKey(
                    password: Array(passphrase.utf8), salt: salt, rounds: rounds, keyLength: keyLength + 12)
                do {
                    let box = try AES.GCM.SealedBox(
                        nonce: AES.GCM.Nonce(data: derived[keyLength...]), ciphertext: privateSection,
                        tag: trailer.prefix(16))
                    plaintext = Array(try AES.GCM.open(box, using: SymmetricKey(data: derived[..<keyLength])))
                } catch {
                    // a failed tag check is how gcm reports a wrong passphrase.
                    throw .wrongPassphrase
                }
            }
        }

        var reader = SSHReader(plaintext)
        // two copies of a random checkint: they only match if decryption worked.
        guard try reader.readUInt32() == reader.readUInt32() else {
            if case .none = cipher { throw .malformed }
            throw .wrongPassphrase
        }
        let material = try Self.readPrivateKey(&reader)
        guard Array(try material.publicKey.blob) == publicBlob else { throw .malformed }
        return material
    }

    /// checks the private key record against its own public half.
    private static func readPrivateKey(_ reader: inout SSHReader) throws(KeyError) -> PrivateKeyMaterial {
        let type = try reader.readText()
        switch type {
        case "ssh-ed25519":
            let publicKey = try reader.readString()
            // 64 bytes: the 32-byte seed followed by the public key again.
            let secret = try reader.readString()
            guard publicKey.count == 32, secret.count == 64, Array(secret[32...]) == publicKey else {
                throw .malformed
            }
            let comment = try reader.readText()
            return PrivateKeyMaterial(kind: .ed25519, data: Data(secret[..<32]), comment: comment)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let kind = KeyKind(curveName: try reader.readText()), type == kind.algorithm else { throw .malformed }
            let point = try reader.readString()
            let scalar = try reader.readMPInt()
            let comment = try reader.readText()
            let material = try KeyImport.ecMaterial(kind: kind, scalar: scalar, comment: comment)
            guard try KeyImport.ecPoint(material) == point else { throw .malformed }
            return material
        case "ssh-rsa":
            let n = try reader.readMPInt()
            let e = try reader.readMPInt()
            let d = try reader.readMPInt()
            let iqmp = try reader.readMPInt()
            let p = try reader.readMPInt()
            let q = try reader.readMPInt()
            let comment = try reader.readText()
            // pkcs#1 also wants the crt exponents, which openssh recomputes on load.
            guard let pMinusOne = BigUInt.decremented(p), let qMinusOne = BigUInt.decremented(q),
                let dP = BigUInt.remainder(d, pMinusOne), let dQ = BigUInt.remainder(d, qMinusOne)
            else { throw .malformed }
            let version: [UInt8] = [0]
            let der = DERWriter.sequence([version, n, e, d, p, q, dP, dQ, iqmp].map(DERWriter.unsignedInteger))
            return try KeyImport.rsa(pkcs1: der, comment: comment)
        case let other where other.hasPrefix("sk-"):
            throw .unsupported("hardware security key (FIDO) keys")
        case "ssh-dss":
            throw .dsaObsolete
        default:
            throw .unsupported(type)
        }
    }

    /// aes-ctr with a big-endian 128-bit counter starting at `iv`, as openssh uses it.
    private static func aesCTR(key: [UInt8], iv: [UInt8], data: [UInt8]) throws(KeyError) -> [UInt8] {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, keyBytes.count, nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == CCCryptorStatus(kCCSuccess), let cryptor else { throw .malformed }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == data.count else { throw .malformed }
        return output
    }
}
