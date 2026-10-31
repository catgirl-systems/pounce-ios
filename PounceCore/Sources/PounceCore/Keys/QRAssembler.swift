import Foundation

extension KeyImport {
    /// chunks are `pounce:<i>/<n>:<base64 chunk>` (1-based); the concatenated base64
    /// decodes to the key text. they arrive in any order and repeat while the camera scans.
    public struct QRAssembler: Sendable {
        private var total: Int?
        private var chunks: [Int: String] = [:]

        public init() {}

        /// true only for a new, consistent chunk (drives haptics); false for repeats,
        /// foreign codes and part counts that disagree with earlier chunks.
        public mutating func add(_ payload: String) -> Bool {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("pounce:") else { return false }
            let parts = trimmed.dropFirst("pounce:".count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return false }
            let position = parts[0].split(separator: "/")
            // cap the part count so a hostile code can't make us track a huge set.
            guard position.count == 2, let index = Int(position[0]), let count = Int(position[1]),
                (1...1000).contains(count), (1...count).contains(index)
            else { return false }
            if let total, total != count { return false }
            let chunk = parts[1].filter { !$0.isWhitespace }
            guard !chunk.isEmpty, chunks[index] == nil else { return false }
            total = count
            chunks[index] = chunk
            return true
        }

        public var progress: (received: Int, total: Int)? {
            total.map { (chunks.count, $0) }
        }

        public var assembled: String? {
            guard let total, chunks.count == total else { return nil }
            let base64 = (1...total).compactMap { chunks[$0] }.joined()
            guard let data = Data(base64Encoded: SSHPublicKey.padded(base64)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
