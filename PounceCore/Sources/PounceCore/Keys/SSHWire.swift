import Foundation

/// ssh wire encoding (rfc 4251 §5). every read is bounds-checked: input is untrusted
struct SSHReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: [UInt8] { Array(bytes[offset...]) }

    mutating func readUInt32() throws(KeyError) -> UInt32 {
        let raw = try readBytes(4)
        return raw.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBytes(_ count: Int) throws(KeyError) -> [UInt8] {
        guard count >= 0, bytes.count - offset >= count else { throw .malformed }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt64() throws(KeyError) -> UInt64 {
        let raw = try readBytes(8)
        return raw.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func readString() throws(KeyError) -> [UInt8] {
        try readBytes(Int(readUInt32()))
    }

    mutating func readText() throws(KeyError) -> String {
        guard let text = String(bytes: try readString(), encoding: .utf8) else { throw .malformed }
        return text
    }

    /// returns the magnitude without sign byte or leading zeros. negative values are
    /// rejected since keys never contain them
    mutating func readMPInt() throws(KeyError) -> [UInt8] {
        let raw = try readString()
        if let first = raw.first, first & 0x80 != 0 { throw .malformed }
        return raw.trimmingLeadingZeros
    }
}

struct SSHWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt32(_ value: UInt32) {
        bytes += value.bigEndianBytes
    }

    mutating func writeUInt64(_ value: UInt64) {
        bytes += value.bigEndianBytes
    }

    mutating func writeString(_ value: Data) { writeString([UInt8](value)) }

    mutating func writeString(_ value: [UInt8]) {
        writeUInt32(UInt32(value.count))
        bytes += value
    }

    mutating func writeString(_ value: String) { writeString(Array(value.utf8)) }
}

extension Data {
    init?(unpaddedBase64 text: String) {
        self.init(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian, Array.init) }
}

extension Array where Element == UInt8 {
    var trimmingLeadingZeros: [UInt8] { Array(drop { $0 == 0 }) }

    /// left-pads or strips leading zeros to exactly `size` bytes for fixed-width ec
    /// scalars, nil when the value doesn't fit
    func leftPadded(to size: Int) -> [UInt8]? {
        let trimmed = trimmingLeadingZeros
        guard trimmed.count <= size else { return nil }
        return [UInt8](repeating: 0, count: size - trimmed.count) + trimmed
    }
}
