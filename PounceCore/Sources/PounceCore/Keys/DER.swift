import Foundation

/// minimal der reader for pkcs#1, sec1 and pkcs#8 keys: single-byte tags and
/// definite lengths only, which is all der allows for these structures.
struct DERReader {
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let sequence: UInt8 = 0x30

    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func read() throws(KeyError) -> (tag: UInt8, content: [UInt8]) {
        guard bytes.count - offset >= 2 else { throw .malformed }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7F
            // four length bytes already cover 4 gib; anything longer is garbage.
            guard (1...4).contains(lengthBytes), bytes.count - offset >= lengthBytes else { throw .malformed }
            length = bytes[offset..<offset + lengthBytes].reduce(0) { ($0 << 8) | Int($1) }
            offset += lengthBytes
        }
        guard bytes.count - offset >= length else { throw .malformed }
        defer { offset += length }
        return (tag, Array(bytes[offset..<offset + length]))
    }

    /// fields of `SEQUENCE { version INTEGER, ... }`, positioned after the version.
    static func versionedSequence(_ der: [UInt8]) throws(KeyError) -> DERReader {
        var outer = DERReader(der)
        var fields = DERReader(try outer.read(sequence))
        _ = try fields.read(integer)
        return fields
    }

    mutating func read(_ tag: UInt8) throws(KeyError) -> [UInt8] {
        let element = try read()
        guard element.tag == tag else { throw .malformed }
        return element.content
    }

    /// non-negative `INTEGER` as an unsigned magnitude without leading zeros.
    mutating func readUnsignedInteger() throws(KeyError) -> [UInt8] {
        let content = try read(Self.integer)
        guard let first = content.first, first & 0x80 == 0 else { throw .malformed }
        return content.trimmingLeadingZeros
    }
}

/// just enough der to rebuild a pkcs#1 `RSAPrivateKey`.
enum DERWriter {
    static func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            let lengthBytes = content.count.bigEndianBytes.trimmingLeadingZeros
            out += [0x80 | UInt8(lengthBytes.count)] + lengthBytes
        }
        return out + content
    }

    static func unsignedInteger(_ magnitude: [UInt8]) -> [UInt8] {
        // der encodes zero as a single 0x00 byte.
        let value = magnitude.signPadded
        return element(DERReader.integer, value.isEmpty ? [0] : value)
    }

    static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        element(DERReader.sequence, elements.flatMap { $0 })
    }
}

/// minimal bigint math for the rsa crt exponents (d mod (p-1), d mod (q-1)) that
/// openssh-key-v1 omits but pkcs#1 requires. values are big-endian magnitudes.
enum BigUInt {
    static func decremented(_ value: [UInt8]) -> [UInt8]? {
        var result = value
        var index = result.count - 1
        while index >= 0 {
            if result[index] > 0 {
                result[index] -= 1
                return result.trimmingLeadingZeros
            }
            result[index] = 0xFF
            index -= 1
        }
        return nil
    }

    /// binary long division, one bit at a time: slow in theory, but only a few hundred
    /// thousand limb operations for a 4096-bit exponent.
    static func remainder(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8]? {
        let m = limbs(modulus)
        guard m.contains(where: { $0 != 0 }) else { return nil }
        // one spare limb holds the bit shifted out before the comparison.
        var r = [UInt32](repeating: 0, count: m.count + 1)
        let mExtended = m + [0]
        for byte in value {
            for bit in stride(from: 7, through: 0, by: -1) {
                var carry = UInt32((byte >> UInt8(bit)) & 1)
                for i in r.indices {
                    let next = r[i] >> 31
                    r[i] = (r[i] << 1) | carry
                    carry = next
                }
                if !isLess(r, mExtended) { subtract(&r, mExtended) }
            }
        }
        return r.reversed().flatMap(\.bigEndianBytes).trimmingLeadingZeros
    }

    /// little-endian 32-bit limbs.
    private static func limbs(_ bytes: [UInt8]) -> [UInt32] {
        var result: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 4)
            result.append(bytes[start..<index].reduce(0) { ($0 << 8) | UInt32($1) })
            index = start
        }
        return result.isEmpty ? [0] : result
    }

    private static func isLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in a.indices {
            let difference = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: difference)
            borrow = (difference >> 63) & 1
        }
    }
}
