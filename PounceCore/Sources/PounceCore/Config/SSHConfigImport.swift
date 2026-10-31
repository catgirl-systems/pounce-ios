import Foundation

/// pattern hosts (`Host *`) aren't imported, but their settings still apply to
/// the hosts they match, first match wins like openssh. `Match` blocks are
/// ignored.
public enum SSHConfigImport {
    public struct Entry: Sendable, Hashable {
        public var alias: String
        public var hostname: String
        public var user: String?
        public var port: Int
        /// aliases or `[user@]host[:port]` specs, in hop order.
        public var proxyJump: [String]
        public var forwards: [Forward]
    }

    public struct Forward: Sendable, Hashable {
        public var kind: Tunnel.Kind
        public var bindPort: Int
        public var targetHost: String
        public var targetPort: Int
    }

    private struct Block {
        var patterns: [String]
        var options: [(String, String)] = []
    }

    public static func parse(_ text: String) -> [Entry] {
        var blocks: [Block] = [Block(patterns: ["*"])]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (key, value) = splitOption(line)
            switch key {
            case "host":
                blocks.append(Block(patterns: value.split(whereSeparator: \.isWhitespace).map(String.init)))
            case "match":
                // `Match` conditions can't be evaluated here; ignore the block.
                blocks.append(Block(patterns: []))
            default:
                blocks[blocks.count - 1].options.append((key, value))
            }
        }

        let aliases = blocks.flatMap(\.patterns).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        var seen = Set<String>()
        return aliases.compactMap { alias in
            guard seen.insert(alias).inserted else { return nil }
            return entry(for: alias, blocks: blocks)
        }
    }

    private static func entry(for alias: String, blocks: [Block]) -> Entry {
        var entry = Entry(alias: alias, hostname: alias, user: nil, port: 22, proxyJump: [], forwards: [])
        var set = Set<String>()
        for block in blocks where matches(alias, block.patterns) {
            for (key, value) in block.options {
                switch key {
                // forwards accumulate; everything else is first match wins.
                case "localforward", "remoteforward":
                    if let forward = parseForward(value, kind: key == "localforward" ? .local : .remote) {
                        entry.forwards.append(forward)
                    }
                case "dynamicforward":
                    if let port = Int(value.split(separator: ":").last ?? "") {
                        entry.forwards.append(Forward(kind: .dynamic, bindPort: port, targetHost: "", targetPort: 0))
                    }
                case _ where !set.insert(key).inserted: break
                case "hostname": entry.hostname = value.replacingOccurrences(of: "%h", with: alias)
                case "user": entry.user = value
                case "port": entry.port = Int(value) ?? 22
                case "proxyjump":
                    entry.proxyJump =
                        value.lowercased() == "none"
                        ? [] : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                default: break
                }
            }
        }
        return entry
    }

    /// `LocalForward [bind:]port host:hostport`, also accepting `host/port`.
    private static func parseForward(_ value: String, kind: Tunnel.Kind) -> Forward? {
        let parts = value.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
            let bind = Int(parts[0].split(separator: ":").last ?? ""),
            let separator = parts[1].lastIndex(where: { $0 == ":" || $0 == "/" }),
            let port = Int(parts[1][parts[1].index(after: separator)...])
        else { return nil }
        let host = String(parts[1][..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Forward(kind: kind, bindPort: bind, targetHost: host, targetPort: port)
    }

    private static func splitOption(_ line: String) -> (String, String) {
        let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) ?? line.endIndex
        let key = line[..<separator].lowercased()
        var value = line[separator...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
        return (key, String(value).trimmingCharacters(in: .whitespaces))
    }

    /// any matching `!pattern` excludes the alias, whatever the other patterns say.
    private static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        !patterns.contains { $0.hasPrefix("!") && glob(String($0.dropFirst()), alias) }
            && patterns.contains { !$0.hasPrefix("!") && glob($0, alias) }
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        func match(_ i: Int, _ j: Int) -> Bool {
            if i == p.count { return j == t.count }
            if p[i] == "*" { return (j...t.count).contains { match(i + 1, $0) } }
            guard j < t.count, p[i] == "?" || p[i] == t[j] else { return false }
            return match(i + 1, j + 1)
        }
        return match(0, 0)
    }
}

/// accepts `[user@]host[:port]` and `ssh user@host -p 2222`.
public enum QuickConnect {
    public static func parse(_ input: String, defaultUser: String = "root") -> SSHEndpoint? {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "ssh" { words.removeFirst() }
        var port: Int?
        var user: String?
        var target: String?
        var iterator = words.makeIterator()
        while let word = iterator.next() {
            switch word {
            case "-p": if let next = iterator.next() { port = Int(next) }
            case "-l": if let next = iterator.next() { user = next }
            case _ where !word.hasPrefix("-"): target = word
            default: break
            }
        }
        guard var rest = target, !rest.isEmpty else { return nil }
        if rest.hasPrefix("ssh://") { rest.removeFirst(6) }
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var host = rest
        // `[v6]:port`, `host:port`, or a bare ipv6 address.
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) ?? port }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...]) ?? port
        }
        guard !host.isEmpty, host.allSatisfy({ !$0.isWhitespace }) else { return nil }
        return SSHEndpoint(host: host, port: port ?? 22, username: user ?? defaultUser)
    }
}
