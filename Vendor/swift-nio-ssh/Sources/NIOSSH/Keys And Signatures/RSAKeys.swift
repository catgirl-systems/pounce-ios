//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// RSA support (pounce vendored patch). RSA keys are backed by the Security framework,
// so this is only available on Darwin platforms.
#if canImport(Darwin)
import Foundation
import NIOCore
import Security

/// An RSA public key, stored as the big-endian bytes of its modulus `n` and public exponent `e`
/// with no leading zero bytes.
internal struct RSAPublicKey: Hashable, Sendable {
    /// The prefix of an RSA public key (RFC 4253 § 6.6).
    static let keyPrefix = "ssh-rsa".utf8

    /// Smallest and largest modulus sizes we accept, in bits. OpenSSH refuses keys below 1024 bits.
    private static let modulusBits = 1024...16384

    let modulus: Data
    let publicExponent: Data

    init<Bytes: Collection>(modulus: Bytes, publicExponent: Bytes) throws where Bytes.Element == UInt8 {
        let modulus = Data(modulus.drop(while: { $0 == 0 }))
        let publicExponent = Data(publicExponent.drop(while: { $0 == 0 }))
        guard Self.modulusBits.contains(modulus.count * 8), let lastExponentByte = publicExponent.last,
            lastExponentByte & 1 == 1, publicExponent.count <= 8
        else {
            throw NIOSSHError.unknownPublicKey(algorithm: "ssh-rsa: unsupported key parameters")
        }
        self.modulus = modulus
        self.publicExponent = publicExponent
    }

    /// Creates a key from a PKCS #1 `RSAPublicKey` DER structure, as returned by `SecKeyCopyExternalRepresentation`.
    init(pkcs1DER der: Data) throws {
        var reader = DERReader(Array(der))
        guard var sequence = reader.read(tag: 0x30), reader.isEmpty,
            let modulus = sequence.read(tag: 0x02), let publicExponent = sequence.read(tag: 0x02), sequence.isEmpty
        else {
            throw NIOSSHError.unknownPublicKey(algorithm: "ssh-rsa: invalid public key encoding")
        }
        try self.init(modulus: modulus.bytes, publicExponent: publicExponent.bytes)
    }

    /// The PKCS #1 `RSAPublicKey` DER structure, as expected by `SecKeyCreateWithData`.
    var pkcs1DER: Data {
        Data(Self.derElement(tag: 0x30, Self.derInteger(self.modulus) + Self.derInteger(self.publicExponent)))
    }

    func isValidSignature(_ signature: RSASignature, for message: Data) -> Bool {
        // Some implementations strip leading zeros from the signature (RFC 8332 § 3), but the
        // Security framework wants it exactly as wide as the modulus.
        guard signature.bytes.count <= self.modulus.count else {
            return false
        }
        let paddedSignature = Data(repeating: 0, count: self.modulus.count - signature.bytes.count) + signature.bytes

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(self.pkcs1DER as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        return SecKeyVerifySignature(
            key,
            signature.algorithm.secKeyAlgorithm,
            message as CFData,
            paddedSignature as CFData,
            nil
        )
    }

    private static func derInteger(_ value: Data) -> [UInt8] {
        // DER integers are signed, so a value with its high bit set needs a leading zero byte.
        let needsLeadingZero = (value.first ?? 0x80) & 0x80 == 0x80
        return self.derElement(tag: 0x02, (needsLeadingZero ? [0] : []) + Array(value))
    }

    private static func derElement(tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        var length = contents.count
        guard length >= 0x80 else {
            return [tag, UInt8(length)] + contents
        }
        var lengthBytes: [UInt8] = []
        while length > 0 {
            lengthBytes.insert(UInt8(truncatingIfNeeded: length), at: 0)
            length >>= 8
        }
        return [tag, 0x80 | UInt8(lengthBytes.count)] + lengthBytes + contents
    }
}

/// A minimal DER reader for the PKCS #1 `RSAPublicKey` structure.
private struct DERReader {
    private(set) var bytes: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) {
        self.bytes = bytes[...]
    }

    private init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
    }

    var isEmpty: Bool { self.bytes.isEmpty }

    /// Reads one element with the given tag and returns a reader over its contents.
    mutating func read(tag: UInt8) -> DERReader? {
        var remaining = self.bytes
        guard remaining.popFirst() == tag, let firstLengthByte = remaining.popFirst() else {
            return nil
        }
        var length = Int(firstLengthByte)
        if firstLengthByte & 0x80 == 0x80 {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard (1...3).contains(lengthByteCount), remaining.count >= lengthByteCount else {
                return nil
            }
            length = remaining.prefix(lengthByteCount).reduce(0) { $0 << 8 | Int($1) }
            remaining = remaining.dropFirst(lengthByteCount)
        }
        guard remaining.count >= length else {
            return nil
        }
        self.bytes = remaining.dropFirst(length)
        return DERReader(remaining.prefix(length))
    }
}

/// An RSA private key held by the Security framework.
internal struct RSAPrivateKey: @unchecked Sendable {
    // SecKey is immutable and safe to use from any thread.
    let key: SecKey
    let publicKey: RSAPublicKey

    init(_ key: SecKey) throws {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as? String, keyType == kSecAttrKeyTypeRSA as String,
            let keyClass = attributes[kSecAttrKeyClass] as? String, keyClass == kSecAttrKeyClassPrivate as String,
            SecKeyIsAlgorithmSupported(key, .sign, RSASignature.Algorithm.sha512.secKeyAlgorithm),
            let secPublicKey = SecKeyCopyPublicKey(key),
            let publicKeyData = SecKeyCopyExternalRepresentation(secPublicKey, nil) as Data?
        else {
            throw NIOSSHError.unknownPublicKey(algorithm: "ssh-rsa: not an RSA private key")
        }
        self.key = key
        self.publicKey = try RSAPublicKey(pkcs1DER: publicKeyData)
    }

    func signature(for message: Data, algorithm: RSASignature.Algorithm) throws -> RSASignature {
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(self.key, algorithm.secKeyAlgorithm, message as CFData, &error)
                as Data?
        else {
            throw error.map { $0.takeRetainedValue() as Error }
                ?? NIOSSHError.unknownPublicKey(algorithm: "ssh-rsa: signing failed")
        }
        return RSASignature(algorithm: algorithm, bytes: signature)
    }
}

/// An RSA signature (RFC 8332).
internal struct RSASignature: Hashable, Sendable {
    enum Algorithm: Hashable, Sendable, CaseIterable {
        case sha256
        case sha512

        /// The signature and public key algorithm name.
        var name: String.UTF8View {
            switch self {
            case .sha256:
                return "rsa-sha2-256".utf8
            case .sha512:
                return "rsa-sha2-512".utf8
            }
        }

        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .sha256:
                return .rsaSignatureMessagePKCS1v15SHA256
            case .sha512:
                return .rsaSignatureMessagePKCS1v15SHA512
            }
        }

        init?<Bytes: Collection>(name: Bytes) where Bytes.Element == UInt8 {
            guard let algorithm = Self.allCases.first(where: { $0.name.elementsEqual(name) }) else {
                return nil
            }
            self = algorithm
        }
    }

    var algorithm: Algorithm
    var bytes: Data
}

extension ByteBuffer {
    /// Writes an RSA public key without its prefix: `mpint e` followed by `mpint n` (RFC 4253 § 6.6).
    mutating func writeRSAPublicKey(baseKey: RSAPublicKey) -> Int {
        self.writePositiveMPInt(baseKey.publicExponent) + self.writePositiveMPInt(baseKey.modulus)
    }

    /// Reads an RSA public key without its prefix.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    mutating func readRSAPublicKey() throws -> NIOSSHPublicKey? {
        guard let publicExponent = self.readSSHString(), let modulus = self.readSSHString() else {
            return nil
        }
        // Both values are positive mpints, so their high bit must be clear.
        guard (publicExponent.readableBytesView.first ?? 0) & 0x80 == 0,
            (modulus.readableBytesView.first ?? 0) & 0x80 == 0
        else {
            throw NIOSSHError.unknownPublicKey(algorithm: "ssh-rsa: negative key parameter")
        }
        let key = try RSAPublicKey(
            modulus: modulus.readableBytesView,
            publicExponent: publicExponent.readableBytesView
        )
        return NIOSSHPublicKey(backingKey: .rsa(key))
    }

    /// Writes an RSA signature: the algorithm name followed by the signature blob (RFC 8332 § 3).
    mutating func writeRSASignature(_ signature: RSASignature) -> Int {
        self.writeSSHString(signature.algorithm.name) + self.writeSSHString(signature.bytes)
    }

    /// Reads an RSA signature blob for an already-read algorithm name.
    ///
    /// Not safe to call from arbitrary code as this does not return the reader index on failure: it relies on the caller performing
    /// the rewind.
    mutating func readRSASignature(algorithm: RSASignature.Algorithm) -> NIOSSHSignature? {
        guard let signatureBytes = self.readSSHString() else {
            return nil
        }
        let signature = RSASignature(algorithm: algorithm, bytes: Data(signatureBytes.readableBytesView))
        return NIOSSHSignature(backingSignature: .rsa(signature))
    }
}
#endif
