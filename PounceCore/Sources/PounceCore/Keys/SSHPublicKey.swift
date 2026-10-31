import CryptoKit
import Foundation
import NIOSSH

public struct SSHPublicKey: Sendable, Hashable {
    /// secure enclave keys report as `.ecdsaP256`: on the wire they're plain p-256 keys.
    public let kind: KeyKind
    public let blob: Data
    public var comment: String
    /// in bits, as `ssh-keygen -l` prints it.
    public let bits: Int

    public init(blob: Data, comment: String = "") throws(KeyError) {
        var reader = SSHReader(Array(blob))
        let algorithm = try reader.readText()
        switch algorithm {
        case "ssh-ed25519":
            guard try reader.readString().count == 32 else { throw .malformed }
            kind = .ed25519
            bits = 256
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let ecdsa = KeyKind(curveName: try reader.readText()), let curve = ecdsa.curve,
                ecdsa.algorithm == algorithm
            else { throw .malformed }
            let point = try reader.readString()
            _ = try keyAttempt {
                switch ecdsa {
                case .ecdsaP256: _ = try P256.Signing.PublicKey(x963Representation: point)
                case .ecdsaP384: _ = try P384.Signing.PublicKey(x963Representation: point)
                default: _ = try P521.Signing.PublicKey(x963Representation: point)
                }
            }
            kind = ecdsa
            bits = curve.bits
        case "ssh-rsa":
            let exponent = try reader.readMPInt()
            let modulus = try reader.readMPInt()
            guard let top = modulus.first, !exponent.isEmpty else { throw .malformed }
            kind = .rsa
            bits = (modulus.count - 1) * 8 + (8 - top.leadingZeroBitCount)
        case "ssh-dss":
            throw .dsaObsolete
        default:
            throw .unsupported(algorithm)
        }
        guard reader.isAtEnd else { throw .malformed }
        self.blob = blob
        self.comment = comment
    }

    init(_ key: NIOSSHPublicKey) throws(KeyError) {
        try self.init(authorizedKeysLine: String(openSSHPublicKey: key))
    }

    /// leading `authorized_keys` options are skipped by looking for the first algorithm name.
    public init(authorizedKeysLine: String) throws(KeyError) {
        let tokens = authorizedKeysLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = tokens.firstIndex(where: { Self.algorithmNames.contains($0) }), index + 1 < tokens.count,
            let blob = Data(base64Encoded: Self.padded(tokens[index + 1]))
        else { throw .unrecognizedFormat }
        try self.init(blob: blob, comment: tokens[(index + 2)...].joined(separator: " "))
        guard algorithm == tokens[index] else { throw .malformed }
    }

    static let algorithmNames: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa", "ssh-dss",
    ]

    static func padded(_ base64: String) -> String {
        base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    }

    public var algorithm: String { kind.algorithm }

    public var authorizedKeysLine: String {
        let line = "\(algorithm) \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// `SHA256:<unpadded base64>`, as `ssh-keygen -l` prints it.
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// openssh's "drunken bishop" randomart, the 11 lines `ssh-keygen -lv` prints.
    /// ported from `fingerprint_randomart` in sshkey.c.
    public var randomart: [String] {
        let width = 17
        let height = 9
        let symbols = Array(" .o+=*BOX@%&#/^SE")
        let maxIndex = symbols.count - 1
        var field = [[Int]](repeating: [Int](repeating: 0, count: height), count: width)
        var x = width / 2
        var y = height / 2

        for byte in SHA256.hash(data: blob) {
            var input = byte
            // each byte holds four 2-bit moves, lowest bits first.
            for _ in 0..<4 {
                x += input & 0x1 != 0 ? 1 : -1
                y += input & 0x2 != 0 ? 1 : -1
                x = min(max(x, 0), width - 1)
                y = min(max(y, 0), height - 1)
                if field[x][y] < maxIndex - 2 { field[x][y] += 1 }
                input >>= 2
            }
        }
        field[width / 2][height / 2] = maxIndex - 1
        field[x][y] = maxIndex

        func border(_ label: String) -> String {
            let leading = (width - label.count) / 2
            let trailing = width - leading - label.count
            return "+" + String(repeating: "-", count: leading) + label + String(repeating: "-", count: trailing) + "+"
        }
        var lines = [border("[\(typeName) \(bits)]")]
        for row in 0..<height {
            lines.append("|" + String((0..<width).map { symbols[min(field[$0][row], maxIndex)] }) + "|")
        }
        lines.append(border("[SHA256]"))
        return lines
    }

    /// short type name openssh uses in randomart titles and `ssh-keygen -l`.
    var typeName: String { kind.curve == nil ? kind.algorithm.dropFirst(4).uppercased() : "ECDSA" }
}
